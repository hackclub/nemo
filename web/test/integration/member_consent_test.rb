require "test_helper"

class MemberConsentTest < ActionDispatch::IntegrationTest
  CAP = "channel_manager".freeze

  setup do
    Fd::Flag.set!(:public_api, true, by: "UBOSS")
    @member = Staff.create!(user_id: "UMEMBER2")
    sign_in_as(@member)
  end

  teardown do
    Fd::Flag.delete_all
    Current.forget_flags
  end

  def flip(on, **extra)
    patch you_consent_path(capability: CAP, on: on, **extra)
  end

  def state
    Api::Consent.find_by(user_id: @member.user_id, capability: CAP)&.state
  end

  test "opting in writes the consent and exactly one log line" do
    assert_difference -> { Api::ConsentLog.count }, 1 do
      flip("1")
    end

    assert_equal "granted", state
    assert_equal "dashboard", Api::ConsentLog.last.via
    assert_equal @member.user_id, Api::ConsentLog.last.user_id
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
    first = Api::Consent.find_by(user_id: @member.user_id, capability: CAP).first_granted_at
    flip("0")

    assert_equal first, Api::Consent.find_by(user_id: @member.user_id, capability: CAP)
      .first_granted_at
  end

  test "a member can only ever move their own row" do
    flip("1", user_id: "UVICTIM", member_id: "UVICTIM")

    assert_equal "granted", state
    assert_nil Api::Consent.find_by(user_id: "UVICTIM")
    assert_empty Api::ConsentLog.where(user_id: "UVICTIM")
  end

  test "a capability nobody declared is refused and writes nothing" do
    assert_no_difference -> { Api::ConsentLog.count } do
      patch you_consent_path(capability: "read_my_email", on: "1")
    end

    assert_redirected_to you_api_path
    assert_match(/not a capability/, flash[:alert])
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

  test "the page offers opting in, then opting out, and counts what is on" do
    get you_api_path

    assert_select ".cap-row .btn", text: "Opt in"
    assert_select ".facts .frow b", text: /nothing/

    flip("1")
    get you_api_path

    assert_select ".cap-row .btn", text: "Opt out"
    assert_select ".facts .frow b", text: /1 of 1/
  end

  test "the switch is dead on the page while the public api is off" do
    Fd::Flag.set!(:public_api, false, by: "UBOSS")
    get you_api_path

    assert_select ".cap-row .btn.is-off"
    assert_select ".cap-row .btn[disabled]"
  end

  test "signed out, nobody can move consent at all" do
    delete logout_path

    assert_no_difference -> { Api::ConsentLog.count } do
      flip("1")
    end

    assert_redirected_to login_path
  end
end
