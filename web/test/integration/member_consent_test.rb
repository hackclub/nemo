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

  def flip(on, app: @client, scope: CAP, **extra)
    patch settings_consent_path(app_id: app.id, scope: scope, on: on, **extra)
  end

  def state(app: @client)
    Api::Consent.find_by(user_id: @member.user_id, app_id: app.id, capability: CAP)&.state
  end

  test "opting in writes the consent and exactly one log line" do
    assert_difference -> { Api::ConsentLog.count }, 1 do
      flip("1")
    end

    assert_equal "granted", state
    assert_equal [@member.user_id, @client.id, "dashboard"],
      Api::ConsentLog.last.then { |log| [log.user_id, log.app_id, log.via] }
  end

  test "opting out again withholds it and logs the second move" do
    flip("1")
    assert_difference -> { Api::ConsentLog.count }, 1 do
      flip("0")
    end

    assert_equal "withheld", state
    assert_equal %w[granted withheld], Api::ConsentLog.order(:at, :id).pluck(:state)
  end

  test "the first grant is remembered even after opting out" do
    flip("1")
    row = Api::Consent.find_by(user_id: @member.user_id, app_id: @client.id, capability: CAP)
    first = row.first_granted_at
    flip("0")

    assert_equal first, row.reload.first_granted_at
  end

  test "one app at a time, so opting in never leaks to another" do
    other = make_app!("UOWNER3", name: "Standup Helper")
    flip("1")

    assert_equal "granted", state
    assert_nil state(app: other)
  end

  test "a member can only ever move their own row" do
    flip("1", user_id: "UVICTIM", member_id: "UVICTIM")

    assert_equal "granted", state
    assert_nil Api::Consent.find_by(user_id: "UVICTIM")
    assert_empty Api::ConsentLog.where(user_id: "UVICTIM")
  end

  test "a scope the app was never approved for is refused" do
    quiet = Api::App.register!("UOWNER4", name: "Quiet", blurb: "asks for nothing yet")

    assert_no_difference -> { Api::ConsentLog.count } do
      flip("1", app: quiet)
    end

    assert_match(/No such app/, flash[:alert])
  end

  test "a scope nobody declared is refused and writes nothing" do
    assert_no_difference -> { Api::ConsentLog.count } do
      flip("1", scope: "read_my_email")
    end

    assert_match(/not a scope/, flash[:alert])
    assert_empty Api::Consent.all
  end

  test "nothing moves while the public api is turned off" do
    Fd::Flag.set!(:public_api, false, by: "UBOSS")

    assert_no_difference -> { Api::ConsentLog.count } do
      flip("1")
    end

    assert_nil state
    assert_match(/turned off/, flash[:alert])
  end

  test "the page lists the app by name and offers opting in, then out" do
    get settings_permissions_path

    assert_select ".fold-title", text: "Triage Bot"
    assert_select ".data-table .switch", text: "Opt in"

    flip("1")
    get settings_permissions_path

    assert_select ".data-table .switch", text: "Opt out"
  end

  test "an app nobody approved is not offered at all" do
    Api::App.register!("UOWNER5", name: "Unapproved", blurb: "has asked for nothing")
    get settings_permissions_path

    assert_select ".fold-title", text: "Unapproved", count: 0
  end

  test "the switch is dead on the page while the public api is off" do
    Fd::Flag.set!(:public_api, false, by: "UBOSS")
    get settings_permissions_path

    assert_select ".data-table .switch[disabled]"
  end

  test "signed out, nobody can move consent at all" do
    delete logout_path

    assert_no_difference -> { Api::ConsentLog.count } do
      flip("1")
    end

    assert_redirected_to login_path
  end
end
