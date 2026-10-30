require "test_helper"

class MemberConsentTest < ActionDispatch::IntegrationTest
  CAP = "channel_manager".freeze

  setup do
    Fd::Flag.set!(:public_api, true, by: "UBOSS")
    @member = Account.create!(user_id: "UMEMBER2")
    @client = make_app!("UOWNER2", name: "Triage Bot")
    sign_in_as(@member)
  end

  teardown do
    Fd::Flag.delete_all
    Current.forget_flags
  end

  def set_consent(on, app: @client, scope: CAP, **extra)
    patch settings_consent_path(app_id: app.id, scope: scope, on: on, **extra)
  end

  def state(app: @client)
    Api::Consent.find_by(user_id: @member.user_id, app_id: app.id, capability: CAP)&.state
  end

  test "opt in sets state granted and writes one ConsentLog row" do
    assert_difference -> { Api::ConsentLog.count }, 1 do
      set_consent("1")
    end

    assert_equal "granted", state
    assert_equal [@member.user_id, @client.id, "dashboard"],
      Api::ConsentLog.last.then { |log| [log.user_id, log.app_id, log.via] }
  end

  test "opt out sets state withheld and writes a second ConsentLog row" do
    set_consent("1")
    assert_difference -> { Api::ConsentLog.count }, 1 do
      set_consent("0")
    end

    assert_equal "withheld", state
    assert_equal %w[granted withheld], Api::ConsentLog.order(:at, :id).pluck(:state)
  end

  test "opt out keeps first_granted_at" do
    set_consent("1")
    row = Api::Consent.find_by(user_id: @member.user_id, app_id: @client.id, capability: CAP)
    first = row.first_granted_at
    set_consent("0")

    assert_equal first, row.reload.first_granted_at
  end

  test "opt in for one app creates no consent for another app" do
    other = make_app!("UOWNER3", name: "Standup Helper")
    set_consent("1")

    assert_equal "granted", state
    assert_nil state(app: other)
  end

  test "opt in ignores user_id and member_id params and writes only the signed in member" do
    set_consent("1", user_id: "UVICTIM", member_id: "UVICTIM")

    assert_equal "granted", state
    assert_nil Api::Consent.find_by(user_id: "UVICTIM")
    assert_empty Api::ConsentLog.where(user_id: "UVICTIM")
  end

  test "opt in for an unapproved app writes no log row and alerts" do
    unapproved_app = Api::App.register!("UOWNER4", name: "Quiet", blurb: "asks for nothing yet")

    assert_no_difference -> { Api::ConsentLog.count } do
      set_consent("1", app: unapproved_app)
    end

    assert_match(/No such app/, flash[:alert])
  end

  test "opt in with an unknown scope writes no row and alerts" do
    assert_no_difference -> { Api::ConsentLog.count } do
      set_consent("1", scope: "read_my_email")
    end

    assert_match(/not a scope/, flash[:alert])
    assert_empty Api::Consent.all
  end

  test "opt in is rejected when the public_api flag is off" do
    Fd::Flag.set!(:public_api, false, by: "UBOSS")

    assert_no_difference -> { Api::ConsentLog.count } do
      set_consent("1")
    end

    assert_nil state
    assert_match(/turned off/, flash[:alert])
  end

  test "permissions page lists the app and switches between Opt in and Opt out" do
    get settings_permissions_path

    assert_select ".fold-title", text: "Triage Bot"
    assert_select ".data-table .switch", text: "Opt in"

    set_consent("1")
    get settings_permissions_path

    assert_select ".data-table .switch", text: "Opt out"
  end

  test "permissions page omits an app without approval" do
    Api::App.register!("UOWNER5", name: "Unapproved", blurb: "has asked for nothing")
    get settings_permissions_path

    assert_select ".fold-title", text: "Unapproved", count: 0
  end

  test "permissions page disables the switch when public_api is off" do
    Fd::Flag.set!(:public_api, false, by: "UBOSS")
    get settings_permissions_path

    assert_select ".data-table .switch[disabled]"
  end

  test "opt in signed out redirects to login and writes no ConsentLog row" do
    delete logout_path

    assert_no_difference -> { Api::ConsentLog.count } do
      set_consent("1")
    end

    assert_redirected_to login_path
  end
end
