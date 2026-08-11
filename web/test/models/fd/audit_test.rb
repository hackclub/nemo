require "test_helper"

class Fd::AuditTest < ActiveSupport::TestCase
  def kase(**attrs)
    Fd::Case.create!({
      subject_user_id: "USUB", opened_by: "UFF1", opened_at: Time.current
    }.merge(attrs))
  end

  def record(target, verb, **opts)
    Fd::Audit.record(target, verb, **{ actor: "UFF1" }.merge(opts))
  end

  test "each conduct record maps to the entity type the seeded trail already uses" do
    assert_equal "case", Fd::Audit.entity_type(Fd::Case.new)
    assert_equal "action", Fd::Audit.entity_type(Fd::Action.new)
    assert_equal "note", Fd::Audit.entity_type(Fd::Note.new)
    assert_equal "report", Fd::Audit.entity_type(Fd::CaseReport.new)
    assert_equal "thread", Fd::Audit.entity_type(Fd::CaseThread.new)
  end

  test "a record outside the conduct schema is refused rather than mislabelled" do
    assert_raises(Fd::Audit::UnauditableRecord) { Fd::Audit.entity_type(Staff.new) }
  end

  test "a verb outside the vocabulary is refused" do
    assert_raises(Fd::Audit::UnknownVerb) { record(kase, "yeeted") }
  end

  test "a create has no before, because there was no before" do
    entry = record(kase, "opened")
    assert_nil entry.before
    assert_equal "USUB", entry.after["subject_user_id"]
  end

  test "an update records both sides of only what moved" do
    target = kase
    target.update!(claimed_by: "UFF2", claimed_at: Time.current)
    entry = record(target, "claimed")
    assert_equal({ "claimed_by" => nil }, entry.before.slice("claimed_by"))
    assert_equal "UFF2", entry.after["claimed_by"]
    assert_not entry.after.key?("subject_user_id")
  end

  test "bookkeeping columns are not audited as changes" do
    target = kase
    target.update!(claimed_by: "UFF2", claimed_at: Time.current)
    entry = record(target, "claimed")
    assert_empty entry.after.keys & Fd::Audit::IGNORED_COLUMNS
  end

  test "a note body is summarised, never copied into the trail" do
    note = Fd::Note.create!(case_id: kase.id, body: "he apologised in DM", author: "UFF1")
    entry = record(note, "noted")
    assert_equal "redacted, 19 chars", entry.after["body"]
    assert_no_match(/apologised/, entry.after.to_json)
  end

  test "what the member was told is summarised too" do
    target = kase
    target.update!(resolved_at: Time.current, resolution: "action_taken", member_note: "we spoke")
    entry = record(target, "resolved")
    assert_equal "redacted, 8 chars", entry.after["member_note"]
    assert_equal "action_taken", entry.after["resolution"]
  end

  test "a redacted column that was empty stays empty rather than reading as text" do
    note = Fd::Note.create!(case_id: kase.id, body: "x", author: "UFF1")
    note.update!(deleted_at: Time.current, deleted_by: "UFF1")
    entry = record(note, "deleted")
    assert_not entry.after.key?("body")
  end

  test "explicit sides win, for writes that never load a row" do
    target = kase
    entry = record(target, "claimed", before: { "claimed_by" => nil }, after: { "claimed_by" => "UFF9" })
    assert_equal "UFF9", entry.after["claimed_by"]
  end

  test "the actor, the request and the source are all recorded" do
    entry = record(kase, "opened", actor: "UFF7", request_id: "req-123")
    assert_equal "UFF7", entry.actor_user_id
    assert_equal "human", entry.actor_kind
    assert_equal "req-123", entry.request_id
    assert_equal "fire_engine", entry.source_app
  end

  test "one request writing several rows ties them together" do
    target = kase
    record(target, "opened", request_id: "req-9")
    record(target, "claimed", request_id: "req-9")
    assert_equal 2, Fd::AuditEntry.where(request_id: "req-9").count
  end

  test "the trail can be appended to but never altered" do
    entry = record(kase, "opened")
    assert_raises(ActiveRecord::ReadOnlyRecord) { entry.update!(verb: "resolved") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { entry.destroy }
  end
end
