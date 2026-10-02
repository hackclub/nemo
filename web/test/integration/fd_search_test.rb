require "test_helper"

class FdSearchTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def found(term)
    get fd_search_path(format: :json), params: { q: term }
    JSON.parse(response.body)
  end

  def group(term, key)
    found(term)["groups"].find { |one| one["key"] == key }
  end

  test "a signed out visitor gets nothing" do
    delete logout_path
    get fd_search_path(format: :json), params: { q: "raid" }

    assert_response :unauthorized
  end

  test "an empty box offers what is waiting and what you can do" do
    make_case(opened_at: 3.days.ago)

    keys = found("")["groups"].map { |one| one["key"] }
    assert_equal ["waiting", "do"], keys

    waiting = group("", "waiting")["rows"]
    assert_match(/unassigned case/, waiting.first["title"])
  end

  test "a case row says what state it is in and who holds it" do
    kase = make_case(opened_at: 2.days.ago, category_key: "spam", assign: "UME")
    kase.update!(member_note: "a raid from six accounts")

    row = group("raid", "case")["rows"].first
    assert_equal "case #{kase.id}", row["title"]
    assert_match(/spam · open/, row["sub"])
    assert_equal fd_case_path(kase), row["url"]
  end

  test "a note row quotes the words around the match and points at its case" do
    kase = make_case(opened_at: 2.days.ago)
    Fd::Note.create!(case_id: kase.id, body: "told them to drop it and they did", author: "UFF1")

    row = group("drop it", "note")["rows"].first
    assert_equal "case #{kase.id}", row["title"]
    assert_includes row["said"], "drop it"
    assert_equal fd_case_path(kase), row["url"]
  end

  test "a group says how many it holds when the rows are capped" do
    kase = make_case(opened_at: 2.days.ago)
    5.times { |n| Fd::Note.create!(case_id: kase.id, body: "raid #{n}", author: "UFF1") }

    notes = group("raid", "note")
    assert_equal 3, notes["rows"].size
    assert_equal 5, notes["total"]
  end

  test "a term nobody typed enough of finds nothing" do
    assert_empty found("a")["groups"].reject { |one| ["waiting", "do"].include?(one["key"]) }
  end

  test "a scope keeps one kind and says so back" do
    kase = make_case(opened_at: 2.days.ago)
    Fd::Note.create!(case_id: kase.id, body: "a raid, six accounts", author: "UFF1")
    make_case(opened_at: 2.days.ago).update!(member_note: "a raid, six accounts")

    get fd_search_path(format: :json), params: { q: "raid", scope: "note" }
    payload = JSON.parse(response.body)

    assert_equal "note", payload["scope"]
    assert_equal ["note"], payload["groups"].map { |one| one["key"] }
  end

  test "a pasted Slack link answers with the case holding that thread" do
    kase = make_case(opened_at: 2.days.ago)
    Fd::CaseThread.create!(case_id: kase.id, channel_id: "C0266FRGV",
      thread_ts: "1754487721.123456", added_by: "UFF1", is_primary: true)

    row = group("https://hackclub.slack.com/archives/C0266FRGV/p1754487721123456", "case")
      .fetch("rows").sole

    assert_equal "case #{kase.id}", row["title"]
    assert_equal fd_case_path(kase), row["url"]
  end

  test "a prefix alone drops the resting rows and shows that kind" do
    make_case(opened_at: 2.days.ago)
    payload = found("#")

    assert_equal "case", payload["scope"]
    assert_equal ["case"], payload["groups"].map { |one| one["key"] }
  end

  test "a chevron turns the box into commands" do
    payload = found(">")

    assert_equal "command", payload["scope"]
    titles = payload["groups"].sole["rows"].map { |row| row["title"] }
    assert_includes titles, "Open a case"
  end

  test "commands filter as you keep typing" do
    titles = found(">members").fetch("groups").sole["rows"].map { |row| row["title"] }

    assert_equal ["Go to the members"], titles
  end

  test "on a case, the commands act on that case" do
    kase = make_case(opened_at: 2.days.ago)
    get fd_search_path(format: :json), params: { q: ">", on_case: kase.id }
    rows = JSON.parse(response.body)["groups"].sole["rows"]

    resolve = rows.find { |row| row["title"] == "Resolve this case" }
    assert_equal "on case #{kase.id}", resolve["sub"]
    assert_equal fd_case_path(kase, do: "resolve"), resolve["url"]
  end

  test "the page lists every group with its count" do
    kase = make_case(opened_at: 2.days.ago)
    kase.update!(member_note: "a raid from six accounts")
    Fd::Note.create!(case_id: kase.id, body: "the raid again", author: "UFF1")

    get fd_search_path(q: "raid")

    assert_response :success
  end
end
