require "test_helper"

class WhoGetsInTest < ActionDispatch::IntegrationTest
  OPEN = %w[sessions rails/health turbo/native/navigation].freeze

  TURBO = %w[/recede_historical_location /resume_historical_location
             /refresh_historical_location].freeze

  INSIDE = %i[root_path fd_root_path fd_members_path fd_decisions_path fd_settings_path].freeze

  MEMBER = %w[you/api you/consents you/tokens docs].freeze

  BEARER = %w[api/v1/tokens api/v1/channel_managers].freeze

  setup do
    Rails.application.eager_load!
    @me = Staff.create!(user_id: "UNOROLE", community_manager: false)
  end

  def self.controllers
    Rails.application.routes.routes.filter_map { |route| route.defaults[:controller] }.uniq
  end

  def filters_of(name)
    "#{name}_controller".camelize.constantize._process_action_callbacks.map(&:filter)
  end

  def guarded?(name)
    filters_of(name).include?(:require_staff)
  end

  def member_guarded?(name)
    filters_of(name).include?(:require_a_member)
  end

  def token_guarded?(name)
    filters_of(name).include?(:require_a_token)
  end

  def guarded_controllers
    (self.class.controllers - OPEN).select do |name|
      guarded?(name) || member_guarded?(name) || token_guarded?(name)
    end
  end

  test "the only routes open to the world are signing in and the health check" do
    assert_equal OPEN.sort, (self.class.controllers - guarded_controllers).sort,
      "a route opened up or closed, so this test needs updating"
  end

  test "every controller behind the login demands a role, bar the member area and the api" do
    (self.class.controllers - OPEN - MEMBER - BEARER).each do |name|
      assert guarded?(name), "#{name} lets anybody through"
      assert_not member_guarded?(name), "#{name} settles for a session where a role is needed"
    end
  end

  test "the member area demands a session and never a role, and is only what is listed" do
    MEMBER.each do |name|
      assert member_guarded?(name), "#{name} lets anybody through"
      assert_not guarded?(name), "#{name} still demands a role, so it is not a member page"
    end

    assert_equal MEMBER.sort,
      (self.class.controllers - OPEN - BEARER).reject { |name| guarded?(name) }.sort,
      "a controller dropped its role check, so this test needs updating"
  end

  test "the api demands a token, never a session or a role, and is only what is listed" do
    BEARER.each do |name|
      assert token_guarded?(name), "#{name} lets anybody through"
      assert_not guarded?(name), "#{name} demands a role, so it is not reachable by a token"
      assert_not member_guarded?(name), "#{name} demands a session, which an api caller has not got"
    end

    assert_equal BEARER.sort,
      (self.class.controllers - OPEN).select { |name| token_guarded?(name) }.sort,
      "a controller started taking bearer tokens, so this test needs updating"
  end

  test "the api carries no session at all, so a browser cannot ride in on cookies" do
    assert_not Api::V1::BaseController.ancestors.include?(ActionController::Cookies),
      "an api controller that reads cookies can be driven by a logged in browser"
    assert_not Api::V1::BaseController.ancestors.include?(ApplicationController)
  end

  test "the turbo routes are open because they carry nothing but a go back" do
    TURBO.each do |path|
      get path
      assert_response :success
      assert_no_match(/case|member|note|decision/i, response.body, "#{path} said something")
    end
  end

  test "holding no grant opens the member area and nothing behind it" do
    sign_in_as(@me)

    assert_redirected_to you_api_path
    assert_equal "UNOROLE", session[:user_id]

    INSIDE.each do |path|
      get send(path)
      assert_redirected_to auth_failure_path(message: "not_allowlisted"),
        "#{path} took a session for a role"
    end
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

  test "somebody unknown to the staff table gets the same member area and no more" do
    sign_in_as(Staff.new(user_id: "USTRANGER"))

    assert_redirected_to you_api_path
    get fd_cases_path
    assert_redirected_to auth_failure_path(message: "not_allowlisted")
  end

  test "the refusal says one thing, and offers the way back" do
    sign_in_as(@me)
    get root_path
    follow_redirect!

    assert_response :success
    assert_select "h1", text: "Access denied"
    assert_select "p", text: /You are not allowlisted/
    assert_select "a[href=?]", you_api_path, 1, "the way out is their own page"
    assert_select "form[action=?]", logout_path
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
    assert_redirected_to auth_failure_path(message: "not_allowlisted")
  end

  test "a stale session lands on the member area rather than bouncing forever" do
    grant = Fd::AccessGrant.give!("UNOROLE", role: "firefighter", by: "UBOSS")
    sign_in_as(@me)
    grant.take_back!(by: "UBOSS")

    get login_path
    assert_redirected_to you_api_path

    follow_redirect!
    assert_response :success
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
