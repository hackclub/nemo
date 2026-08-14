require "test_helper"

class FdSearchTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
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
    assert_empty response.body
  end

  test "an empty box offers what is waiting and what you can do" do
    make_case(opened_at: 3.days.ago)
    Fd::Decision.create!(title: "Second chances", statement: "read by somebody else",
      proposed_by: "UFF1")

    keys = found("")["groups"].map { |one| one["key"] }
    assert_equal ["waiting", "do"], keys

    waiting = group("", "waiting")["rows"]
    assert_match(/unassigned case/, waiting.first["title"])
    assert_match(/\A#{Fd::Decision.unsettled.count} proposals? to settle\z/,
      waiting.last["title"])
    assert_equal fd_decisions_path(view: "proposed"), waiting.last["url"]
  end

  test "a decision row carries where it stands and what it is called" do
    decision = Fd::Decision.create!(title: "Throwaway accounts", proposed_by: "UFF1",
      statement: "A brand new handle posting a banjo link is banned on sight.")
    decision.settle!(by: "ULEAD")

    row = group("banjo", "decision")["rows"].sole
    assert_equal "Throwaway accounts", row["title"]
    assert_equal "in force", row["sub"]
    assert_equal fd_decision_path(decision), row["url"]
    assert_equal "📓", row["icon"]
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
    decision = Fd::Decision.create!(title: "Raid nights", proposed_by: "UFF1",
      statement: "a raid is locked on sight")
    decision.settle!(by: "ULEAD")
    make_case(opened_at: 2.days.ago).update!(member_note: "a raid, six accounts")

    get fd_search_path(format: :json), params: { q: "raid", scope: "decision" }
    payload = JSON.parse(response.body)

    assert_equal "decision", payload["scope"]
    assert_equal ["decision"], payload["groups"].map { |one| one["key"] }
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
    assert_includes titles, "Write a decision"
  end

  test "commands filter as you keep typing" do
    titles = found(">write").fetch("groups").sole["rows"].map { |row| row["title"] }

    assert_equal ["Write a decision"], titles
  end

  test "on a case, the commands act on that case" do
    kase = make_case(opened_at: 2.days.ago)
    get fd_search_path(format: :json), params: { q: ">", on_case: kase.id }
    rows = JSON.parse(response.body)["groups"].sole["rows"]

    resolve = rows.find { |row| row["title"] == "Resolve this case" }
    assert_equal "on case #{kase.id}", resolve["sub"]
    assert_equal fd_case_path(kase, do: "resolve"), resolve["url"]
  end

  test "a command lands with the modal already open" do
    kase = make_case(opened_at: 2.days.ago)

    get fd_case_path(kase, do: "resolve")
    assert_select "input#resolve-case[checked]"

    get fd_case_path(kase)
    assert_select "input#resolve-case[checked]", count: 0
  end

  test "a decision command opens its modal too" do
    decision = Fd::Decision.create!(title: "Second chances", statement: "read by somebody else",
      proposed_by: "UME")

    get fd_search_path(format: :json), params: { q: ">", on_decision: decision.id }
    rows = JSON.parse(response.body)["groups"].sole["rows"]
    assert_includes rows.map { |row| row["title"] }, "Link threads"

    get fd_decision_path(decision, do: "edit")
    assert_select "input#edit-decision[checked]"
  end

  test "the page lists every group with its count" do
    kase = make_case(opened_at: 2.days.ago)
    kase.update!(member_note: "a raid from six accounts")
    Fd::Note.create!(case_id: kase.id, body: "the raid again", author: "UFF1")

    get fd_search_path(q: "raid")

    assert_response :success
    assert_select ".head-title", text: "raid"
    assert_select ".head-meta", text: /hits in \d+ms/
    assert_select ".band-label", text: /Cases · 1/
    assert_select ".band-label", text: /Notes · 1/
    assert_select "a[href=?]", fd_case_path(kase)
  end

  test "a tab on the page keeps one kind" do
    kase = make_case(opened_at: 2.days.ago)
    kase.update!(member_note: "a raid from six accounts")
    Fd::Note.create!(case_id: kase.id, body: "the raid again", author: "UFF1")

    get fd_search_path(q: "raid", scope: "note")

    assert_select ".band-label", text: /Notes · 1/
    assert_select ".band-label", text: /Cases/, count: 0
    assert_select ".view[aria-current]", text: /Notes/
    assert_select "a.view", text: /Cases\s*1/, count: 1
    assert_select "a.view[href=?]", fd_search_path(q: "raid")
  end

  test "the page says when it found nothing, and when it was not asked" do
    get fd_search_path(q: "nothingmatchesthis")
    assert_select ".card-note", text: "Nothing found."

    get fd_search_path
    assert_select ".card-note", text: "Type at least two letters."
  end

  test "the palette carries a scope chip and the tab hint" do
    get fd_cases_path

    assert_select ".palette-input .scope[hidden]"
    assert_select ".palette-foot", text: /tab/
  end

  test "the palette and its opener are on every page" do
    get fd_cases_path

    assert_select "[data-controller~=palette]"
    assert_select ".palette-host input[data-palette-target=input]"
    assert_select "button.field-top[data-action='palette#open']"
  end
end
