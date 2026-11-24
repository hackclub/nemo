require "test_helper"

class FdMemberActionsTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  SUBJECT = "UACTIONS1".freeze

  setup do
    @boss = grant_role!("UACTBOSS", "community_manager")
    sign_in_as(@boss)
  end

  def action!(kase, type_key, performed_at, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: type_key, target_user_id: SUBJECT, decided_by: "UMOD",
                         performed_by: "UMOD", performed_at: performed_at, source_app: "lyla" }.merge(attrs))
  end

  def names = css_select(".action-entry-name").map { |node| node.text.squish }

  test "actions tab lists case actions, no-case guards and pfp removals newest first" do
    kase = make_case(subject: SUBJECT, category_key: "spam")
    action!(kase, "temp_ban", 10.days.ago, expires_at: 3.days.ago, reversed_at: 8.days.ago,
      reversed_by: "UMOD", reversal_reason: "appeal accepted")
    action!(kase, "warning", 3.days.ago, reason: "same link in three channels")
    Fd::MemberGuard.create!(kind: "shush", subject_id: SUBJECT, opened_by: "UMOD", reason: "flooding",
      opened_at: 20.days.ago, state: "lifted", lifted_at: 19.days.ago, lifted_by: "UMOD",
      enforced_by: "nemo", enforcement_status: "held")
    Fd::PhotoRemoval.create!(member_id: SUBJECT, asked_by: "UMOD", reason: "inappropriate image",
      state: "done", asked_at: 15.days.ago, finished_at: 14.days.ago)

    get fd_member_path(SUBJECT)

    assert_equal ["Warning", "Temporary ban", "Pfp removed", "Shush"], names
    assert_select ".action-entry-state", text: /Reversed/
    assert_select ".action-entry-state", text: /Lifted/
    assert_select ".action-entry-reason", text: "same link in three channels"
    assert_select ".action-entry-category", text: "No case", count: 2
  end

  test "actions tab links each case action to the case card thread" do
    kase = make_case(subject: SUBJECT, category_key: "spam", card_channel_id: "C0FIREHOSE", card_thread_ts: "1700000000.000300")
    action!(kase, "warning", 2.days.ago)
    Fd::CaseThread.create!(case_id: kase.id, channel_id: "C0INCIDENT", thread_ts: "1700000000.000100",
      is_primary: true, kind: "evidence", added_by: "UMOD")

    get fd_member_path(SUBJECT)

    assert_select %(a.thread-link[href="https://hackclub.slack.com/archives/C0FIREHOSE/p1700000000000300"][target=_blank]),
      text: "Case Thread"
    assert_select "a.thread-link", count: 1
    assert_select ".action-entry-meta a[href='#{fd_case_path(kase)}']", text: "Case #{kase.id}"
  end

  test "actions tab falls back to an internal case thread without a card thread" do
    kase = make_case(subject: SUBJECT, category_key: "spam")
    action!(kase, "warning", 2.days.ago)
    Fd::CaseThread.create!(case_id: kase.id, channel_id: "C0INTERNAL", thread_ts: "1700000000.000200",
      is_primary: false, kind: "internal", added_by: "UMOD")

    get fd_member_path(SUBJECT)

    assert_select %(a.thread-link[href="https://hackclub.slack.com/archives/C0INTERNAL/p1700000000000200"]), text: "Case Thread"
  end

  test "actions tab shows no thread link when the case has only evidence threads" do
    kase = make_case(subject: SUBJECT, category_key: "spam")
    action!(kase, "warning", 2.days.ago)
    Fd::CaseThread.create!(case_id: kase.id, channel_id: "C0INCIDENT", thread_ts: "1700000000.000100",
      is_primary: true, kind: "evidence", added_by: "UMOD")

    get fd_member_path(SUBJECT)

    assert_select ".action-entry", count: 1
    assert_select "a.thread-link", count: 0
  end

  test "actions tab leaves out notes and cases without actions" do
    make_case(subject: SUBJECT)
    Fd::Note.create!(subject_user_id: SUBJECT, body: "context only", author: "UMOD")

    get fd_member_path(SUBJECT)

    assert_select ".action-entry", count: 0
    assert_select ".empty-title", text: "No actions"
  end

  test "history tab keeps the full timeline" do
    Fd::Note.create!(subject_user_id: SUBJECT, body: "context only", author: "UMOD")

    get fd_member_path(SUBJECT, tab: "history")

    assert_select ".member-timeline .member-event-body", text: /context only/
    assert_select "nav.member-record-tabs a[aria-current=true]", text: /History/
  end
end
