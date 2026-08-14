require "test_helper"

class WhoGetsInTest < ActionDispatch::IntegrationTest
  OPEN = %w[sessions rails/health turbo/native/navigation].freeze

  TURBO = %w[/recede_historical_location /resume_historical_location
             /refresh_historical_location].freeze

  INSIDE = %i[root_path fd_root_path fd_members_path fd_decisions_path fd_settings_path].freeze

  setup do
    Rails.application.eager_load!
    @me = Staff.create!(user_id: "UNOROLE", community_manager: false)
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

  test "holding no grant means no session, whatever the staff table says" do
    sign_in_as(@me)

    assert_redirected_to auth_failure_path(message: "no_access")
    assert_nil session[:user_id]
  end

  test "somebody unknown to the staff table is refused the same way" do
    sign_in_as(Staff.new(user_id: "USTRANGER"))

    assert_redirected_to auth_failure_path(message: "no_access")
    assert_nil session[:user_id]
  end

  test "the refusal says one thing, and offers the way back" do
    sign_in_as(@me)
    follow_redirect!

    assert_response :success
    assert_select "h1", text: "Access denied"
    assert_select "p", text: /You do not have access to Mnemosyne/
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
    assert_redirected_to auth_failure_path(message: "no_access")
  end

  test "a stale session lands on the sign in page rather than bouncing forever" do
    grant = Fd::AccessGrant.give!("UNOROLE", role: "firefighter", by: "UBOSS")
    sign_in_as(@me)
    grant.take_back!(by: "UBOSS")

    get login_path

    assert_response :success
    assert_select "h1", text: /sign in/i
  end

  test "a json endpoint says no rather than handing back a login page" do
    get fd_search_path(format: :json, q: "anything")

    assert_response :unauthorized
    assert_empty response.body
  end

  test "the three roles are the only things that count as a role" do
    %w[firefighter lead community_manager].each do |role|
      Fd::AccessGrant.give!("UNOROLE", role: role, by: "UBOSS")
      assert_equal role, Staff.find("UNOROLE").role
    end

    assert_raises(Fd::AccessGrant::NotAllowed) do
      Fd::AccessGrant.give!("UNOROLE", role: "observer", by: "UBOSS")
    end
  end
end
