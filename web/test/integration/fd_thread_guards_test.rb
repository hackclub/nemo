require "test_helper"

class FdThreadGuardsTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
    @kase = make_case(subject: "USUB")
  end

  def guard!(**over)
    Fd::ThreadGuard.create!({
      kind: "lock", channel_id: "C0266FRGV", thread_ts: "1700000000.000100",
      opened_by: "UMOD", reason: "it was going nowhere", state: "running",
      expires_at: 3.days.from_now, case_id: @kase.id
    }.merge(over))
  end

  def actions_tab
    get fd_case_path(@kase, tab: "actions")
    response.body
  end

  test "a locked thread on the case is shown beside its actions" do
    guard!
    body = actions_tab

    assert_match(/Thread locked/, body)
    assert_match(/it was going nowhere/, body)
    assert_match(/running/, body)
  end

  test "a destroyed thread reads as destroyed" do
    guard!(kind: "destroy", expires_at: nil, state: "done")
    assert_match(/Thread destroyed/, actions_tab)
  end

  test "the note left in the thread is shown with the guard" do
    guard!(kind: "destroy", expires_at: nil, state: "done",
      note_rich: { "type" => "rich_text" }, note_text: "we took this down, here is why",
      note_ts: "1700000000.000200", note_posted_at: Time.current)

    assert_match(/we took this down, here is why/, actions_tab)
  end

  test "a destroy with no note says nothing extra" do
    guard!(kind: "destroy", expires_at: nil, state: "done")

    assert_no_match(/lcite/, actions_tab)
  end

  test "a guard that failed is called out" do
    guard!(state: "failed", error: "the admin account could not be invited")
    body = actions_tab
    assert_match(/failed/, body)
    assert_match(/state-crit/, body)
  end

  test "a thread guard on another case is not listed here" do
    other = make_case
    guard!(case_id: other.id)
    actions_tab
    assert_select ".thread-guard-list", false
  end

  test "a thread guard tied to no case is not listed here" do
    guard!(case_id: nil)
    actions_tab
    assert_select ".thread-guard-list", false
  end
end
