require "test_helper"

class FdMessagesTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UFF1", community_manager: false)
    Fd::AccessGrant.give!("UFF1", role: "firefighter", by: "UBOSS")
    sign_in_as(@me)
  end

  test "a confirmation lands in the top bar, in the search line's place" do
    kase = make_case

    post fd_case_claim_path(kase)
    follow_redirect!

    assert_select ".topbar .topbar-msg", text: /case #{kase.id} is yours/
    assert_select ".topbar-msg[role=?][data-toast-delay-value=?]", "status", "3000"
  end

  test "a refusal stays twice as long, and says so to a screen reader" do
    kase = make_case(assign: "UOTHER")

    post fd_case_resolution_path(kase), params: { outcome: "close", close_reason: "no_action" }
    follow_redirect!

    assert_select ".topbar-msg.topbar-msg-alert[role=?][data-toast-delay-value=?]", "alert", "6000",
      text: /assigned to @UOTHER, not to you/
  end

  test "a page with nothing to say carries no message at all" do
    get fd_cases_path
    get fd_cases_path

    assert_select ".topbar .field-top"
    assert_select ".topbar-msg", count: 0
  end

  test "the message does not follow you to the next page" do
    kase = make_case

    post fd_case_claim_path(kase)
    follow_redirect!
    assert_select ".topbar-msg[data-controller=?]", "toast"

    get fd_case_path(kase)
    assert_select ".topbar-msg", count: 0
  end

  test "nothing floats over the page any more" do
    kase = make_case

    post fd_case_claim_path(kase)
    follow_redirect!

    assert_select ".toast-stack", count: 0
    assert_select ".toast", count: 0
  end
end
