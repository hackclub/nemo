require "test_helper"

class Fd::DeedsTest < ActiveSupport::TestCase
  WHO = "UFF1".freeze

  def audit(entity_type, entity_id, verb, at: 1.hour.ago, actor: WHO, after: nil)
    Fd::AuditEntry.create!(actor_user_id: actor, actor_kind: "human", entity_type: entity_type,
      entity_id: entity_id, verb: verb, source_app: "fire_engine", occurred_at: at,
      after: after)
  end

  def deeds(only: nil, **opts)
    Fd::Deeds.new(WHO, since: 30.days.ago, only: only, **opts).rows
  end

  test "a case deed links the case it happened on" do
    kase = make_case
    audit("case", kase.id, "resolved")

    row = deeds.sole
    assert_equal "case/resolved", row.event
    assert_equal ["case", kase.id, "case #{kase.id}"], [row.kind, row.id, row.about]
  end

  test "an action deed names what was done and to whom, and links the case" do
    kase = make_case
    action = Fd::Action.create!(case_id: kase.id, type_key: "temp_ban",
      target_user_id: "USUB", decided_by: WHO, performed_by: WHO)
    audit("action", action.id, "performed")

    row = deeds.sole
    assert_equal ["case", kase.id], [row.kind, row.id]
    assert_equal ["temp ban", "USUB"], [row.said, row.who]
  end

  test "a note written about a member rather than a case links the member" do
    note = Fd::Note.create!(subject_user_id: "USUB", body: "keep an eye", author: WHO)
    audit("note", note.id, "noted")

    row = deeds.sole
    assert_equal ["member", "USUB"], [row.kind, row.id]
  end

  test "the things filed on a case all point back at the case" do
    kase = make_case
    %w[participant thread citation assignee].each { |type| audit(type, kase.id, "attached") }

    assert_equal [kase.id] * 4, deeds.map(&:id)
    assert_equal ["case"] * 4, deeds.map(&:kind)
  end

  test "a grant deed names who got it and what they got" do
    grant = Authz::Grant.give!("UNEW", kind: "role", name: "firefighter", by: WHO)
    audit("capability_grant", grant.id, "granted",
      after: { "user_id" => "UNEW", "role" => "firefighter" })

    row = deeds.sole
    assert_equal ["member", "UNEW", "firefighter"], [row.kind, row.id, row.said]
  end

  test "asking for one permission keeps only the events that permission covers" do
    kase = make_case
    action = Fd::Action.create!(case_id: kase.id, type_key: "warning", target_user_id: "USUB",
      decided_by: WHO, performed_by: WHO)
    audit("action", action.id, "performed")
    audit("case", kase.id, "opened")

    assert_equal ["action/performed"], deeds(only: "case.act").map(&:event)
    assert_equal ["case/opened"], deeds(only: "case.open").map(&:event)
  end

  test "a permission with no events of its own asks for nothing" do
    audit("case", make_case.id, "opened")

    assert_empty deeds(only: "case.read")
  end

  test "identity reads come from the access log, not the audit" do
    audit("case", make_case.id, "opened")
    AccessLog.create!(actor_id: WHO, subject_user_id: "USUB", field_class: "identity",
      looked_at: 2.days.ago)

    row = deeds(only: "identity.read").sole
    assert_equal ["identity/read", "member", "USUB"], [row.event, row.kind, row.id]
  end

  test "a refusal is not something they did" do
    audit("case", 0, "refused")

    assert_empty deeds
  end

  test "somebody else's work is not theirs, and neither is last quarter's" do
    kase = make_case
    audit("case", kase.id, "opened", actor: "UOTHER")
    audit("case", kase.id, "reopened", at: 2.months.ago)

    assert_empty deeds
  end

  test "the newest come first, and no more than asked for" do
    kase = make_case
    audit("case", kase.id, "opened", at: 3.days.ago)
    audit("case", kase.id, "claimed", at: 1.day.ago)
    audit("case", kase.id, "resolved", at: 2.hours.ago)

    assert_equal %w[case/resolved case/claimed], deeds(limit: 2).map(&:event)
  end

  test "the members it mentions are the ones a name is needed for" do
    kase = make_case
    action = Fd::Action.create!(case_id: kase.id, type_key: "warning", target_user_id: "USUB",
      decided_by: WHO, performed_by: WHO)
    audit("action", action.id, "performed")
    note = Fd::Note.create!(subject_user_id: "UWATCHED", body: "keep an eye", author: WHO)
    audit("note", note.id, "noted")

    assert_equal ["UWATCHED", "USUB", WHO].sort,
      Fd::Deeds.new(WHO, since: 30.days.ago).member_ids.sort,
      "the actor is named too, so an audit log can say who did it"
  end
end
