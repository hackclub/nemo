require "test_helper"

class Fd::DeedsTest < ActiveSupport::TestCase
  WHO = "UFF1".freeze

  def audit(entity_type, entity_id, verb, at: 1.hour.ago, actor: WHO)
    Fd::AuditEntry.create!(actor_user_id: actor, actor_kind: "human", entity_type: entity_type,
      entity_id: entity_id, verb: verb, source_app: "fire_engine", occurred_at: at)
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

  test "a thread linked to a decision reads as the decision, not the thread" do
    decision = Fd::Decision.create!(title: "Dogpiling", statement: "one warning each",
      proposed_by: WHO, proposed_at: 2.days.ago)
    audit("decision_thread", decision.id, "attached")

    row = deeds.sole
    assert_equal ["decision", decision.id, "Dogpiling"], [row.kind, row.id, row.about]
  end

  test "a grant deed names who got it and what they got" do
    grant = Fd::AccessGrant.give!("UNEW", role: "lead", by: WHO)
    audit("grant", grant.id, "granted")

    row = deeds.sole
    assert_equal ["member", "UNEW", "lead"], [row.kind, row.id, row.said]
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

  def both_kinds
    audit("case", make_case.id, "opened")
    AccessLog.create!(actor_id: WHO, subject_user_id: "USUB", field_class: "identity",
      looked_at: 2.days.ago)
  end

  def all_three
    both_kinds
    Api::Consent.set!(WHO, "channel_manager", true, via: "dashboard")
  end

  test "a view keeps only its own source, and no view keeps nothing" do
    all_three

    assert_equal %w[case/opened consent/granted identity/read], deeds.map(&:event).sort
    assert_equal ["case/opened"], deeds(view: "audit").map(&:event)
    assert_equal ["identity/read"], deeds(view: "read").map(&:event)
    assert_equal ["consent/granted"], deeds(view: "api").map(&:event)
  end

  test "a consent change names the capability and how it was made, not a member link" do
    Api::Consent.set!(WHO, "channel_manager", true, via: "command")

    row = deeds(view: "api").sole
    assert_equal ["capability", "channel manager lookups"], [row.kind, row.about]
    assert_equal ["from Slack", WHO], [row.said, row.actor]
    assert_nil row.id, "a consent row links nothing, it is about the person who made it"
  end

  test "opting back out reads as its own line, and both survive" do
    Api::Consent.set!(WHO, "channel_manager", true, via: "dashboard")
    Api::Consent.set!(WHO, "channel_manager", false, via: "dashboard")

    assert_equal ["consent/granted", "consent/withheld"], deeds(view: "api").map(&:event).sort,
      "one line each way, whatever order a shared timestamp puts them in"
  end

  def checked(token, on: "C0DESIGN99", subjects: ["USUB"], outcome: "manager", at: 1.hour.ago)
    Api::RequestLog.insert_all(subjects.map do |subject|
      { token_id: token.id, channel_id: on, subject_user_id: subject,
        outcome: outcome, at: at }
    end)
  end

  test "a day of api traffic reads as one line, not one line a call" do
    token, = Api::Token.mint!(WHO, "Toolbox")
    checked(token, subjects: %w[U1 U2 U3])

    row = deeds(view: "api").sole
    assert_equal ["api/checked", "3 members", WHO], [row.event, row.about, row.actor]
    assert_equal "Toolbox · 1 channel", row.said
  end

  test "the roll up counts channels and what was withheld" do
    token, = Api::Token.mint!(WHO, "Toolbox")
    checked(token, on: "C0ONE", subjects: %w[U1 U2])
    checked(token, on: "C0TWO", subjects: %w[U3], outcome: "withheld")

    assert_equal "Toolbox · 2 channels · 1 withheld", deeds(view: "api").sole.said
  end

  test "two days of traffic are two lines, and two tokens are two more" do
    mine, = Api::Token.mint!(WHO, "Toolbox")
    theirs, = Api::Token.mint!("UOTHER", "Arcade")
    checked(mine, at: 1.hour.ago)
    checked(mine, at: 2.days.ago)
    checked(theirs, at: 1.hour.ago)

    assert_equal 3, Fd::Deeds.new(nil, since: 30.days.ago, view: "api").rows.size
  end

  test "a token owner sees their own traffic and not somebody else's" do
    mine, = Api::Token.mint!(WHO, "Toolbox")
    theirs, = Api::Token.mint!("UOTHER", "Arcade")
    checked(mine)
    checked(theirs)

    assert_equal ["Toolbox · 1 channel"], deeds(view: "api").map(&:said)
  end

  test "the api count covers consent, events and traffic alike" do
    token, = Api::Token.mint!(WHO, "Toolbox")
    checked(token, subjects: %w[U1 U2])
    Api::Consent.set!(WHO, "channel_manager", true, via: "dashboard")
    Api::Event.record!("token_minted", actor: WHO, subject: token.shown, detail: "Toolbox")

    counted = Fd::Deeds.new(WHO, since: 30.days.ago).totals
    assert_equal 3, counted["api"], "one roll up, one consent line, one event"
    assert_equal deeds(view: "api").size, counted["api"]
  end

  test "consent changes are asked for by nobody looking at one permission" do
    Api::Consent.set!(WHO, "channel_manager", true, via: "dashboard")
    audit("case", make_case.id, "opened")

    assert_equal ["case/opened"], deeds(only: "case.open").map(&:event)
    assert_empty deeds(only: "identity.read")
  end

  test "an unknown view falls back to everything rather than to nothing" do
    both_kinds

    assert_equal deeds.size, deeds(view: "nonsense").size
    assert_equal "all", Fd::Deeds.view_for("nonsense")
    assert_equal "all", Fd::Deeds.view_for(nil)
  end

  test "the per-view counts add up to the unfiltered total" do
    all_three
    counted = Fd::Deeds.new(WHO, since: 30.days.ago).totals

    assert_equal 1, counted["audit"]
    assert_equal 1, counted["read"]
    assert_equal 1, counted["api"]
    assert_equal counted["all"], counted["audit"] + counted["read"] + counted["api"]
    assert_equal Fd::Deeds.new(WHO, since: 30.days.ago).total, counted["all"]
  end

  test "counting a view agrees with paging it" do
    all_three
    counted = Fd::Deeds.new(WHO, since: 30.days.ago).totals

    Fd::Deeds::VIEWS.each_key do |key|
      assert_equal deeds(view: key).size, counted.fetch(key),
        "#{key} counts one way and pages another"
    end
  end

  test "a view still counts every source when there is nothing to count" do
    counted = Fd::Deeds.new(WHO, since: 30.days.ago).totals

    assert_equal({ "audit" => 0, "read" => 0, "api" => 0, "all" => 0 }, counted)
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
