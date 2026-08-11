require "test_helper"

class FdHelperTest < ActionView::TestCase
  include FdHelper

  def entry(**attrs)
    Fd::AuditEntry.new({
      occurred_at: Time.current, actor_kind: "human", entity_type: "case",
      entity_id: 1, verb: "opened", source_app: "fire_engine"
    }.merge(attrs))
  end

  test "a human acting through fire engine needs no qualifier" do
    assert_nil audit_actor_note(entry(actor_user_id: "UFF1"))
  end

  test "an entry with no actor names the source instead of repeating its kind" do
    note = audit_actor_note(entry(actor_user_id: nil, actor_kind: "system", source_app: "shroud"))
    assert_equal "via shroud", note
    assert_equal "arrived on its own", audit_actor_label(entry(actor_user_id: nil, actor_kind: "system"))
  end

  test "a bot is labelled by name and marked automatic" do
    row = entry(actor_user_id: "UMNEMOSYNE", actor_kind: "bot", source_app: "firehose")
    assert_equal "@UMNEMOSYNE", audit_actor_label(row)
    assert_equal "automatic · via firehose", audit_actor_note(row)
  end

  test "change notes read as prose, not as column names" do
    assert_equal "about @U1", audit_change_note(entry(after: { "subject_user_id" => "U1" }))
    assert_equal "as no action", audit_change_note(entry(after: { "resolution" => "no_action" }))
    assert_equal "anonymous", audit_change_note(entry(after: { "is_anonymous" => true }))
    assert_equal "identified", audit_change_note(entry(after: { "is_anonymous" => false }))
  end

  test "keys that duplicate another column are left out" do
    assert_nil audit_change_note(entry(verb: "claimed", after: { "claimed_by" => "UFF1" }))
  end

  test "null values are dropped rather than printed" do
    note = audit_change_note(entry(after: { "type_key" => "warning", "expires_at" => nil }))
    assert_equal "Warning", note
  end

  test "an iso timestamp in a payload is rendered as a date" do
    note = audit_change_note(entry(after: { "expires_at" => "2026-03-04T05:06:07+00:00" }))
    assert_equal "expires Mar 4, 2026", note
  end

  test "an empty payload yields nothing to say" do
    assert_nil audit_change_note(entry(after: nil))
    assert_nil audit_change_note(entry(after: {}))
  end

  test "the trail summary distinguishes a burst from a long case" do
    now = Time.current
    burst = [entry(occurred_at: now), entry(occurred_at: now + 5.minutes)]
    assert_equal "2 entries, all within the hour", audit_trail_summary(burst)
    spread = [entry(occurred_at: now), entry(occurred_at: now + 3.days)]
    assert_equal "2 entries over 3d", audit_trail_summary(spread)
    assert_equal "nothing recorded yet", audit_trail_summary([])
  end

  test "note counts name where each note is attached" do
    one = Fd::Note.new(case_id: 1, body: "b", author: "UFF1")
    standing = Fd::Note.new(subject_user_id: "U1", body: "b", author: "UFF1")
    assert_equal "nothing written down yet", note_count_summary([], [])
    assert_equal "1 on this case", note_count_summary([one], [])
    assert_equal "1 on this case · 1 standing on the member", note_count_summary([one], [standing])
  end

  test "a note byline credits its author and age" do
    note = Fd::Note.new(body: "b", author: "UFF1", created_at: 3.days.ago)
    assert_equal "@UFF1 · 3d ago", note_byline(note)
  end
end
