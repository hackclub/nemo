require "test_helper"

class Fd::SearchTest < ActiveSupport::TestCase
  def look(term, **options)
    Fd::Search.new(term, **options)
  end

  def kinds(term)
    look(term).groups.map(&:key)
  end

  def rows(term, kind, limit: Fd::Search::LIMIT)
    look(term, limit: limit).groups.find { |group| group.key == kind }&.rows.to_a
  end

  def ranked(term)
    rows(term, "member", limit: 50).map { |row| row.record.user_id }
  end

  def decision(**attrs)
    Fd::Decision.create!({ title: "Spam accounts", proposed_by: "UFF1",
      statement: "A first-post account posting an invite link is banned on sight." }.merge(attrs))
  end

  test "a term nobody typed asks the database nothing" do
    assert_not_predicate look(""), :asked?
    assert_not_predicate look(" a "), :asked?
    assert_empty look("").groups
  end

  test "a group with nothing in it is left out" do
    decision(title: "Pile-ons", statement: "one lock and a note to the loudest three")

    assert_equal ["decision"], kinds("loudest")
  end

  test "a decision is found by its name, its sentence or one of its reasons" do
    decision(reasons: ["warning a throwaway does nothing"])

    assert_equal ["Spam accounts"], rows("spam", "decision").map { |row| row.record.title }
    assert_equal ["Spam accounts"], rows("invite link", "decision").map { |row| row.record.title }
    assert_equal ["Spam accounts"], rows("throwaway", "decision").map { |row| row.record.title }
    assert_empty rows("banjo", "decision")
  end

  test "a case is found by its number, however it is typed" do
    kase = make_case(opened_at: 2.days.ago)

    [kase.id.to_s, "case #{kase.id}", "##{kase.id}"].each do |typed|
      assert_equal [kase.id], rows(typed, "case").map { |row| row.record.id }, typed
    end
  end

  test "a case is found by the reason it was resolved with" do
    kase = make_case(opened_at: 3.days.ago)
    kase.update!(resolved_at: 1.day.ago, resolution: "no_action",
      member_note: "both sides were rude, told them to drop it")

    assert_includes rows("drop it", "case").map { |row| row.record.id }, kase.id
  end

  test "a case is found by who it is about" do
    member = Fd::Member.live.first
    kase = make_case(subject: member.user_id, opened_at: 2.days.ago)

    found = look(member.handle.presence || member.display_name)
    assert_includes found.groups.map(&:key), "case"
    assert_includes found.groups.find { |group| group.key == "case" }.rows.map { |row| row.record.id },
      kase.id
  end

  test "a note is found by what it says, and a deleted one is not" do
    kase = make_case(opened_at: 2.days.ago)
    kept = Fd::Note.create!(case_id: kase.id, body: "asked them to drop it", author: "UFF1")
    Fd::Note.create!(case_id: kase.id, body: "drop it, again", author: "UFF1",
      deleted_at: Time.current, deleted_by: "UFF1")

    assert_equal [kept.id], rows("drop it", "note").map { |row| row.record.id }
  end

  test "a report is found by what the reporter wrote" do
    kase = make_case(opened_at: 2.days.ago)
    report = Fd::CaseReport.create!(case_id: kase.id, is_anonymous: true, source_app: "shroud",
      received_at: 1.day.ago, body: "a raid from six day-old accounts")

    assert_equal [report.id], rows("raid", "report").map { |row| row.record.id }
  end

  test "each group says how many it holds, even when the rows are capped" do
    kase = make_case(opened_at: 2.days.ago)
    5.times { |n| Fd::Note.create!(case_id: kase.id, body: "raid number #{n}", author: "UFF1") }

    found = look("raid", limit: 3).groups.sole
    assert_equal 3, found.rows.size
    assert_equal 5, found.total
    assert_equal 5, look("raid").total
  end

  test "a text row carries the words around the match, not the whole body" do
    kase = make_case(opened_at: 2.days.ago)
    Fd::Note.create!(case_id: kase.id, author: "UFF1",
      body: "#{'a lot of preamble that nobody needs to read ' * 4}the raid came from six accounts")

    said = rows("raid", "note").sole.said
    assert_includes said, "raid"
    assert said.length <= Fd::Search::WINDOW + 2, "the snippet ran long: #{said.length}"
    assert said.start_with?("…"), "a snippet cut from the middle says so"
  end

  test "a short body is quoted whole" do
    kase = make_case(opened_at: 2.days.ago)
    Fd::Note.create!(case_id: kase.id, body: "the raid again", author: "UFF1")

    assert_equal "the raid again", rows("raid", "note").sole.said
  end

  test "an open case outranks a resolved one" do
    old = make_case(opened_at: 3.days.ago)
    old.update!(resolved_at: 1.day.ago, resolution: "no_action",
      member_note: "the raid was over by then")
    open = make_case(opened_at: 4.days.ago)
    open.update!(member_note: "the raid is still going")

    found = rows("raid", "case").map { |row| row.record.id }
    assert_equal [open.id, old.id], found & [open.id, old.id]
  end

  test "the case whose number was typed comes first" do
    asked = make_case(opened_at: 5.days.ago)
    asked.update!(member_note: "the raid started here")
    make_case(opened_at: 1.hour.ago).update!(member_note: "another raid, newer")

    assert_equal asked.id, rows(asked.id.to_s, "case").first.record.id
  end

  test "a rule in force outranks a proposal, and a retired one comes last" do
    dead = decision(title: "Warnings by DM", statement: "a raid gets a warning")
    dead.settle!(by: "ULEAD")
    rule = decision(title: "Raid nights", statement: "a raid is locked on sight")
    rule.settle!(by: "ULEAD")
    dead.supersede!(rule, by: "ULEAD")
    proposal = decision(title: "Raid appeals", statement: "a raid ban is appealable")

    assert_equal [rule.id, proposal.id, dead.id],
      rows("raid", "decision").map { |row| row.record.id }
  end

  test "somebody with a conduct history outranks a quiet namesake" do
    before = ranked("na")
    quiet, noisy = before.last(2)
    skip "the corpus has no two quiet members sharing a name" if quiet.nil? || quiet == noisy

    make_case(subject: noisy, opened_at: 2.days.ago)

    after = ranked("na")
    assert after.index(noisy) < after.index(quiet),
      "a member with a case must climb above a quiet namesake"
  end

  test "the groups keep one order, whatever matched" do
    member = Fd::Member.live.first
    make_case(subject: member.user_id, opened_at: 2.days.ago)
    decision(title: member.display_name.to_s, statement: "something about them")

    assert_equal ["member", "case", "decision"], kinds(member.display_name)
  end
end
