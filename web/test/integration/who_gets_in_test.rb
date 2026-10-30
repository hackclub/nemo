require "test_helper"

class WhoGetsInTest < ActionDispatch::IntegrationTest
  OPEN = %w[sessions health rails/pwa turbo/native/navigation].freeze

  TURBO = %w[/recede_historical_location /resume_historical_location
             /refresh_historical_location].freeze

  SIGN_IN_REQUIRED_PATHS = %i[root_path fd_root_path fd_members_path admin_people_path].freeze

  MEMBER = %w[settings/keys settings/tokens settings/apps settings/consents
              settings/permissions settings/appearances docs accounts workspace_logo
              channels home fd/slack_accounts].freeze

  ROLE_GATES = %i[require_fd require_admin require_operating require_reading
                  require_reviewer].freeze

  BEARER = %w[api/v1/tokens api/v1/channel_managers].freeze

  setup do
    Rails.application.eager_load!
    @me = Account.create!(user_id: "UNOROLE")
  end

  def self.controllers
    Rails.application.routes.routes.filter_map { |route| route.defaults[:controller] }.uniq
  end

  def filters_of(name)
    "#{name}_controller".camelize.constantize._process_action_callbacks.map(&:filter)
  end

  def guarded?(name)
    filters_of(name).include?(:require_account)
  end

  def role_guarded?(name)
    filters_of(name).intersect?(ROLE_GATES)
  end

  def token_guarded?(name)
    filters_of(name).include?(:require_token)
  end

  def guarded_controllers
    (self.class.controllers - OPEN).select do |name|
      guarded?(name) || token_guarded?(name)
    end
  end

  test "controllers without an auth filter equal OPEN" do
    assert_equal OPEN.sort, (self.class.controllers - guarded_controllers).sort,
      "the set of open controllers changed"
  end

  test "controllers not in OPEN or MEMBER or BEARER require an account and a role gate" do
    (self.class.controllers - OPEN - MEMBER - BEARER).each do |name|
      assert guarded?(name), "#{name} has no require_account"
      assert role_guarded?(name), "#{name} has no role gate"
    end
  end

  test "MEMBER controllers require an account with no role gate and are the only ones" do
    MEMBER.each do |name|
      assert guarded?(name), "#{name} has no require_account"
      assert_not role_guarded?(name), "#{name} has a role gate but is listed in MEMBER"
    end

    assert_equal MEMBER.sort,
      (self.class.controllers - OPEN - BEARER).reject { |name| role_guarded?(name) }.sort,
      "controllers without a role gate differ from MEMBER"
  end

  test "BEARER controllers require a token without an account and are the only such controllers" do
    BEARER.each do |name|
      assert token_guarded?(name), "#{name} has no require_token"
      assert_not guarded?(name), "#{name} requires a session"
    end

    assert_equal BEARER.sort,
      (self.class.controllers - OPEN).select { |name| token_guarded?(name) }.sort,
      "controllers with require_token differ from BEARER"
  end

  test "Api::V1::BaseController includes neither Cookies nor ApplicationController" do
    assert_not Api::V1::BaseController.ancestors.include?(ActionController::Cookies),
      "Api::V1::BaseController includes ActionController::Cookies"
    assert_not Api::V1::BaseController.ancestors.include?(ApplicationController)
  end

  test "turbo history routes return success with no case or member or note text" do
    TURBO.each do |path|
      get path
      assert_response :success
      assert_no_match(/case|member|note/i, response.body, "#{path} body names a case, member or note")
    end
  end

  test "pwa manifest signed out returns the app name with no case or member or note text" do
    get pwa_manifest_path(format: :json)

    assert_response :success
    assert_equal "Mnemosyne", JSON.parse(response.body)["name"]
    assert_no_match(/case|member|note/i, response.body, "manifest body names a case, member or note")
  end

  test "sign in without a grant sets the session and renders root" do
    sign_in_as(@me)

    assert_equal @me.user_id, session[:user_id]

    get root_path
    assert_response :success
  end

  test "grant without an Account row allows fd_cases_path after sign in" do
    Authz::Grant.create!(user_id: "UNOROW", kind: "role", name: "firefighter",
      effect: "allow", granted_by: "UNOROLE", granted_at: Time.current)
    assert_nil Account.find_by(user_id: "UNOROW"), "grant exists without an Account row"

    sign_in_as(Account.new(user_id: "UNOROW"))

    assert_equal "UNOROW", session[:user_id]
    get fd_cases_path
    assert_response :success
  end

  test "sign in with an unknown user_id creates an Account without Fire Engine access" do
    sign_in_as(Account.new(user_id: "USTRANGER"))

    assert_equal "USTRANGER", session[:user_id]
    assert Account.exists?("USTRANGER"), "signing in through Hack Club makes the row"

    get fd_cases_path
    assert_redirected_to root_path, "account without a grant is redirected to root"
  end

  test "auth failure page renders for no_slack_id" do
    get auth_failure_path(message: "no_slack_id")

    assert_response :success
  end

  test "signed out requests to protected paths redirect to login" do
    SIGN_IN_REQUIRED_PATHS.each do |path|
      get send(path)
      assert_redirected_to login_path, "#{path} does not redirect to login"
    end
  end

  test "granting a role creates the Account row and an effective role" do
    assert_not Account.exists?("UFRESH")

    grant_role!("UFRESH", "firefighter")

    assert Account.exists?("UFRESH")
    assert_equal %w[firefighter], Authz.effective_roles("UFRESH")
  end

  test "revoking the role redirects fd_root_path to root with an access alert" do
    grant_role!("UNOROLE", "firefighter")
    sign_in_as(@me)

    get fd_root_path
    assert_response :success

    revoke_roles!("UNOROLE")

    get fd_root_path
    assert_redirected_to root_path,
      "revoked grant redirects Fire Engine to root"
    assert_match(/Fire Engine access required/, flash[:alert])
  end

  test "login page redirects a session to root after its roles are dropped" do
    grant_role!("UNOROLE", "firefighter")
    sign_in_as(@me)
    revoke_roles!("UNOROLE")

    get login_path

    assert_redirected_to root_path, "signed in session redirects to root"
  end

  test "dev_be_path is not routed and the dev path returns 404" do
    assert_not Rails.application.routes.url_helpers.respond_to?(:dev_be_path)

    get "/dev/be/UNOROLE"

    assert_response :not_found
    assert_nil session[:user_id]
  end

  test "json fd search signed out returns 401 with an empty body" do
    get fd_search_path(format: :json, q: "anything")

    assert_response :unauthorized
    assert_empty response.body
  end

  test "effective_roles returns each grantable role and grant! raises for an unknown role" do
    Authz.grantable_roles.each do |role|
      grant_role!("UNOROLE", role)
      Current.forget_roles
      assert_equal [role], Authz.effective_roles("UNOROLE"),
        "effective_roles returns the granted role"
    end

    assert_raises(Authz::Grant::NotAllowedError) do
      Authz::Grant.grant!("UNOROLE", kind: "role", name: "wizard", by: "test")
    end
  end

  test "community_manager role yields MANAGER_ROLE and the checked capabilities" do
    manager = grant_role!("UABOVE", "community_manager")

    assert_equal [Fd::Access::MANAGER_ROLE], Authz.effective_roles(manager.user_id),
      "effective_roles returns MANAGER_ROLE"
    assert_predicate manager, :manager?
    assert manager.may?("case.read"), "manager lacks case.read"
    assert Authz.holds?(manager, "channel.all"), "manager lacks channel.all"
    assert Authz.holds?(manager, "engine.manage"), "manager lacks engine.manage"
    assert Authz.holds?(manager, "access.grant"), "manager lacks access.grant"
  end
end
