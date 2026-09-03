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

  test "a term nobody typed asks the database nothing" do
    assert_not_predicate look(""), :asked?
    assert_not_predicate look(" a "), :asked?
    assert_empty look("").groups
  end

  test "a group with nothing in it is left out" do
    kase = make_case(opened_at: 2.days.ago)
    Fd::Note.create!(case_id: kase.id, body: "the noisiest one yet", author: "UFF1")

    assert_equal ["note"], kinds("noisiest")
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

  test "somebody with a conduct history outranks a quiet namesake" do
    before = ranked("na")
    quiet, noisy = before.last(2)
    skip "the corpus has no two quiet members sharing a name" if quiet.nil? || quiet == noisy

    make_case(subject: noisy, opened_at: 2.days.ago)

    after = ranked("na")
    assert after.index(noisy) < after.index(quiet),
      "a member with a case must climb above a quiet namesake"
  end

  test "a prefix narrows the search to one kind" do
    member = Fd::Member.live.first
    make_case(subject: member.user_id, opened_at: 2.days.ago)
    name = member.handle.presence || member.display_name

    assert_includes kinds(name), "case"
    assert_equal ["member"], kinds("@#{name}")
    assert_equal ["case"], kinds("##{name}")
  end

  test "a prefix on its own shows that kind straight away" do
    kase = make_case(subject: Fd::Member.live.first.user_id, opened_at: 2.days.ago)
    Fd::Note.create!(case_id: kase.id, body: "a note about the raid", author: "UFF1")

    assert_equal ["case"], kinds("#")
    assert_equal ["note"], kinds("n:")
    assert_equal ["member"], kinds("@")
    assert rows("#", "case").any?, "an empty case scope still lists cases"
  end

  test "an open case leads the list a bare scope shows" do
    open = make_case(opened_at: 1.hour.ago)
    make_case(opened_at: 30.minutes.ago).update!(resolved_at: Time.current,
      resolution: "no_action")

    assert_equal open.id, rows("#", "case").first.record.id
  end

  test "a bare scope counts what it showed, not the whole table" do
    make_case(opened_at: 2.days.ago)
    found = look("#").groups.sole

    assert_equal found.rows.size, found.total
    assert_nil found.rows.first.said
  end

  test "a scope passed on its own does the same as a prefix" do
    kase = make_case(opened_at: 2.days.ago)
    kase.update!(member_note: "a raid, six accounts")
    Fd::Note.create!(case_id: kase.id, body: "a note about the raid", author: "UFF1")

    assert_equal ["case", "note"], kinds("raid")
    assert_equal ["note"], look("raid", scope: "note").groups.map(&:key)
  end

  test "a scoped search shows more of the one kind it kept" do
    kase = make_case(opened_at: 2.days.ago)
    6.times { |n| Fd::Note.create!(case_id: kase.id, body: "raid #{n}", author: "UFF1") }

    assert_equal 3, rows("raid", "note").size
    assert_equal 6, look("raid", scope: "note").groups.sole.rows.size
  end

  test "a scope nobody offered is ignored" do
    Fd::Note.create!(subject_user_id: "USUB", body: "a raid, six accounts", author: "UFF1")

    assert_equal ["note"], look("raid", scope: "vibes").groups.map(&:key)
  end

  test "a pasted Slack link finds the case holding that thread" do
    kase = make_case(opened_at: 2.days.ago)
    Fd::CaseThread.create!(case_id: kase.id, channel_id: "C0266FRGV",
      thread_ts: "1754487721.123456", added_by: "UFF1", is_primary: true)

    link = "https://hackclub.slack.com/archives/C0266FRGV/p1754487721123456"
    assert_equal [kase.id], rows(link, "case").map { |row| row.record.id }
  end

  test "a link to a thread nobody kept finds nothing" do
    link = "https://hackclub.slack.com/archives/C0NOTHING/p1754487721123456"

    assert_predicate look(link), :asked?
    assert_empty look(link).groups
  end

  test "the groups keep one order, whatever matched" do
    member = Fd::Member.live.first
    make_case(subject: member.user_id, opened_at: 2.days.ago)

    assert_equal ["member", "case"], kinds(member.display_name)
  end
end
