require "test_helper"

class WhoGetsInTest < ActionDispatch::IntegrationTest
  OPEN = %w[sessions rails/health rails/pwa turbo/native/navigation].freeze

  TURBO = %w[/recede_historical_location /resume_historical_location
             /refresh_historical_location].freeze

  INSIDE = %i[root_path fd_root_path fd_members_path fd_decisions_path admin_people_path].freeze

  setup do
    Rails.application.eager_load!
    @me = Staff.create!(user_id: "UNOROLE")
  end

  def self.controllers
    Rails.application.routes.routes.filter_map { |route| route.defaults[:controller] }.uniq
  end

  def guarded?(name)
    "#{name}_controller".camelize.constantize._process_action_callbacks
      .any? { |callback| callback.filter == :require_staff }
  end

  def guarded_controllers
    (self.class.controllers - OPEN).select { |name| guarded?(name) }
  end

  test "the only routes open to the world are signing in and the health check" do
    assert_equal OPEN.sort, (self.class.controllers - guarded_controllers).sort,
      "a route opened up or closed, so this test needs updating"
  end

  test "every controller behind the login demands a role, not merely a session" do
    (self.class.controllers - OPEN).each do |name|
      assert guarded?(name), "#{name} lets anybody through"
    end
  end

  test "the turbo routes are open because they carry nothing but a go back" do
    TURBO.each do |path|
      get path
      assert_response :success
      assert_no_match(/case|member|note|decision/i, response.body, "#{path} said something")
    end
  end

  test "the manifest is open because the browser fetches it before anybody signs in" do
    get pwa_manifest_path(format: :json)

    assert_response :success
    assert_equal "Mnemosyne", JSON.parse(response.body)["name"]
    assert_no_match(/case|member|note|decision/i, response.body, "the manifest said something")
  end

  test "holding no grant still gets a session, and only the front door" do
    sign_in_as(@me)

    assert_equal @me.user_id, session[:user_id]

    get root_path
    assert_response :success
    assert_select ".card-title", text: "Open to everyone", count: 0,
      message: "the overview is open to every signed-in member now"
  end

  test "a live grant is enough on its own, with no staff row behind it" do
    Fd::AccessGrant.create!(user_id: "UNOROW", role: "firefighter",
      granted_by: "UNOROLE", granted_at: Time.current)
    assert_nil Staff.find_by(user_id: "UNOROW"), "the seeder writes grants without staff rows"

    sign_in_as(Staff.new(user_id: "UNOROW"))

    assert_equal "UNOROW", session[:user_id]
    get fd_cases_path
    assert_response :success
  end

  test "somebody unknown to the staff table signs in and gets a row" do
    sign_in_as(Staff.new(user_id: "USTRANGER"))

    assert_equal "USTRANGER", session[:user_id]
    assert Staff.exists?("USTRANGER"), "signing in through Hack Club makes the row"

    get fd_cases_path
    assert_redirected_to root_path, "a stranger still holds nothing"
  end

  test "the refusal says one thing, and offers the way back" do
    get auth_failure_path(message: "not_allowlisted")

    assert_response :success
    assert_select "h1", text: "Access denied"
    assert_select "p", text: /You are not allowlisted/
    assert_select "a[href=?]", login_path
    assert_select ".auth-alt", count: 0
  end

  test "a visitor with no session is sent to sign in, not to the refusal" do
    INSIDE.each do |path|
      get send(path)
      assert_redirected_to login_path, "#{path} did not ask for a sign in"
    end
  end

  test "giving somebody a grant is what puts them on the staff table" do
    assert_not Staff.exists?("UFRESH")

    Fd::AccessGrant.give!("UFRESH", role: "firefighter", by: "UBOSS")

    assert Staff.exists?("UFRESH")
    assert_equal "firefighter", Staff.find("UFRESH").role
  end

  test "a grant taken back shuts the door on the next request" do
    grant = Fd::AccessGrant.give!("UNOROLE", role: "firefighter", by: "UBOSS")
    sign_in_as(@me)

    get fd_root_path
    assert_response :success

    grant.take_back!(by: "UBOSS")

    get fd_root_path
    assert_redirected_to root_path,
      "losing the grant shuts Fire Engine, it no longer shuts the whole app"
    assert_match(/conduct team/, flash[:alert])
  end

  test "a stale session lands on the sign in page rather than bouncing forever" do
    grant = Fd::AccessGrant.give!("UNOROLE", role: "firefighter", by: "UBOSS")
    sign_in_as(@me)
    grant.take_back!(by: "UBOSS")

    get login_path

    assert_redirected_to root_path, "a live session is sent on, not asked to sign in again"
  end

  test "the sign in switch for development is not routed anywhere else" do
    assert_not Rails.application.routes.url_helpers.respond_to?(:dev_be_path)

    get "/dev/be/UNOROLE"

    assert_response :not_found
    assert_nil session[:user_id]
  end

  test "a json endpoint says no rather than handing back a login page" do
    get fd_search_path(format: :json, q: "anything")

    assert_response :unauthorized
    assert_empty response.body
  end

  test "the grantable roles are the only things that count as a role" do
    Fd::Permission::GRANTABLE.each do |role|
      Fd::AccessGrant.give!("UNOROLE", role: role, by: "UBOSS")
      Current.forget_roles
      wanted = role == "lead" ? "firefighter" : role
      assert_equal wanted, Staff.find("UNOROLE").role,
        "the lead ladder is gone, a lead grant reads as a firefighter"
    end

    assert_raises(Fd::AccessGrant::NotAllowed) do
      Fd::AccessGrant.give!("UNOROLE", role: "observer", by: "UBOSS")
    end
  end

  test "the manager sits above both ladders, held by the flag" do
    boss = hold_role!("UABOVE", "community_manager")

    assert_equal Fd::Access::MANAGER_ROLE, boss.role,
      "the manager role is what a manager holds now"
    assert_predicate boss, :manager?
    assert boss.may?("case.read"), "a manager runs the Fire Department"
    assert Authz.holds?(boss, "channel.all"), "a manager reads every channel"
    assert Authz.holds?(boss, "engine.tune"), "a manager runs the engine"
    assert Authz.holds?(boss, "access.grant"), "a manager hands access out"
  end
end
