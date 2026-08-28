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

    assert_select ".topbar-msg .msg-title", text: /case #{kase.id} is yours/
    assert_select ".topbar-msgs[aria-live=?]", "polite"
    assert_select ".topbar-msg.topbar-msg-good[data-toast-delay-value=?]", "3000"
  end

  test "a refusal holds until it is closed, and says what was not done" do
    kase = make_case(assign: "UOTHER")

    post fd_case_actions_path(kase), params: { kind: "warning", about: "USUB" }
    follow_redirect!

    assert_select ".topbar-msg.topbar-msg-bad[data-toast-delay-value=?]", "0"
    assert_select ".topbar-msg .msg-title", text: /assigned to @UOTHER, not to you/
    assert_select ".topbar-msg .msg-said", text: /Nothing was changed/
    assert_select ".topbar-msg .msg-shut"
  end

  test "a confirmation that leads somewhere offers the way there" do
    post fd_member_notes_path("USUB"), params: { body: "keeps at it" }
    follow_redirect!

    assert_select ".topbar-msg .msg-did a[href=?]", fd_member_path("USUB"),
      text: "See their record"
  end

  test "a page with nothing to say carries no message at all" do
    get fd_cases_path
    get fd_cases_path

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
