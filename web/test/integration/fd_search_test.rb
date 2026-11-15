require "test_helper"

class FdSearchTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  setup do
    @me = grant_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def search_json(term)
    get fd_search_path(format: :json), params: { q: term }
    JSON.parse(response.body)
  end

  def group(term, key)
    search_json(term)["groups"].find { |one| one["key"] == key }
  end

  test "search json after logout returns 401" do
    delete logout_path
    get fd_search_path(format: :json), params: { q: "raid" }

    assert_response :unauthorized
  end

  test "search with empty q returns groups waiting do page" do
    make_case(opened_at: 3.days.ago)

    keys = search_json("")["groups"].map { |one| one["key"] }
    assert_equal ["waiting", "do", "page"], keys

    waiting = group("", "waiting")["rows"]
    assert_match(/unassigned case/, waiting.first["title"])
  end

  test "search case row has case title and category state sub and case url" do
    kase = make_case(opened_at: 2.days.ago, category_key: "spam", assign: "UME")
    kase.update!(member_note: "a raid from six accounts")

    row = group("raid", "case")["rows"].first
    assert_equal "case #{kase.id}", row["title"]
    assert_match(/spam, mass pings or invites · open/, row["sub"])
    assert_equal fd_case_path(kase), row["url"]
  end

  test "search member row sub counts priors and open cases" do
    member!("U0PALETTE1", handle: "quorvexpalette")
    action_taken_case = make_case(subject: "U0PALETTE1", opened_at: 20.days.ago, resolved_at: 10.days.ago,
      resolution: "action_taken")
    Fd::Action.create!(case_id: action_taken_case.id, type_key: "warning", target_user_id: "U0PALETTE1",
      decided_by: "UFF1", performed_by: "UFF1")
    make_case(subject: "U0PALETTE1", opened_at: 2.days.ago)

    row = group("quorvexpalette", "member")["rows"].find { |one| one["id"] == "U0PALETTE1" }
    assert_match(/1 prior/, row["sub"])
    assert_match(/1 open/, row["sub"])
  end

  test "search note row has case title and match snippet and case url" do
    kase = make_case(opened_at: 2.days.ago)
    Fd::Note.create!(case_id: kase.id, body: "told them to drop it and they did", author: "UFF1")

    row = group("drop it", "note")["rows"].first
    assert_equal "case #{kase.id}", row["title"]
    assert_includes row["snippet"], "drop it"
    assert_equal fd_case_path(kase), row["url"]
  end

  test "search group caps rows at 3 and reports total" do
    kase = make_case(opened_at: 2.days.ago)
    5.times { |n| Fd::Note.create!(case_id: kase.id, body: "raid #{n}", author: "UFF1") }

    notes = group("raid", "note")
    assert_equal 3, notes["rows"].size
    assert_equal 5, notes["total"]
  end

  test "search with one character q returns only waiting and do groups" do
    assert_empty search_json("a")["groups"].reject { |one| ["waiting", "do"].include?(one["key"]) }
  end

  test "search with empty q lists sidebar pages under Go to label" do
    pages = group("", "page")["rows"].map { |one| one["title"] }

    assert_equal "Go to", group("", "page")["label"]
    assert_includes pages, "Cases"
    assert_includes pages, "Audit log"
  end

  test "search page group matches word prefix in page title" do
    assert_equal ["Audit log"], group("aud", "page")["rows"].map { |one| one["title"] }
    assert_equal ["Audit log"], group("log", "page")["rows"].map { |one| one["title"] }
  end

  test "search audit group links to audit with last:30d" do
    row = group("raid", "audit")["rows"].first

    assert_equal "Audit log: raid", row["title"]
    assert_equal fd_audit_path(q: "raid last:30d"), row["url"]
  end

  test "search audit group maps ip or email or phrase to qualifiers" do
    assert_equal fd_audit_path(q: "ip:10.1.2.3 last:30d"), group("10.1.2.3", "audit")["rows"].first["url"]
    assert_equal fd_audit_path(q: "email:pix@example.net last:30d"),
      group("pix@example.net", "audit")["rows"].first["url"]
    assert_equal fd_audit_path(q: %("two words" last:30d)), group("two words", "audit")["rows"].first["url"]
  end

  test "search cluster group row has Clusters label and accounts sub and cluster url" do
    member!("UPIXRINGA", handle: "pixringa")
    member!("UPIXRINGB", handle: "pixringb")
    %w[UPIXRINGA UPIXRINGB].each do |user_id|
      as_pipeline("INSERT INTO fd.member_cluster (user_id, cluster_id, accounts, ring, active) " \
                  "VALUES (?, 'UPIXRINGA', 2, true, true)", user_id)
      seeded!("fd.member_cluster", "user_id", user_id)
    end

    row = group("pixringb", "cluster")["rows"].first

    assert_equal "Clusters", group("pixringb", "cluster")["label"]
    assert_match(/cluster\z/, row["title"])
    assert_equal "2 accounts · ring", row["sub"]
    assert_equal fd_cluster_path("UPIXRINGA"), row["url"]
  end

  test "search with scope note returns only note group and scope" do
    kase = make_case(opened_at: 2.days.ago)
    Fd::Note.create!(case_id: kase.id, body: "a raid, six accounts", author: "UFF1")
    make_case(opened_at: 2.days.ago).update!(member_note: "a raid, six accounts")

    get fd_search_path(format: :json), params: { q: "raid", scope: "note" }
    payload = JSON.parse(response.body)

    assert_equal "note", payload["scope"]
    assert_equal ["note"], payload["groups"].map { |one| one["key"] }
  end

  test "search with Slack thread link returns the case with that thread" do
    kase = make_case(opened_at: 2.days.ago)
    Fd::CaseThread.create!(case_id: kase.id, channel_id: "C0266FRGV",
      thread_ts: "1754487721.123456", added_by: "UFF1", is_primary: true)

    row = group("https://hackclub.slack.com/archives/C0266FRGV/p1754487721123456", "case")
      .fetch("rows").sole

    assert_equal "case #{kase.id}", row["title"]
    assert_equal fd_case_path(kase), row["url"]
  end

  test "search with Slack thread link skips a thread removed from the case" do
    kase = make_case(opened_at: 2.days.ago)
    Fd::CaseThread.create!(case_id: kase.id, channel_id: "C0266FRGV", thread_ts: "1754487721.123456",
      added_by: "UFF1", removed_at: Time.current, removed_by: "UFF1")

    rows = group("https://hackclub.slack.com/archives/C0266FRGV/p1754487721123456", "case")&.fetch("rows")

    assert_empty Array(rows)
  end

  test "search with hash prefix only returns scope case and case group" do
    make_case(opened_at: 2.days.ago)
    payload = search_json("#")

    assert_equal "case", payload["scope"]
    assert_equal ["case"], payload["groups"].map { |one| one["key"] }
  end

  test "search with chevron returns command scope and Open case command" do
    payload = search_json(">")

    assert_equal "command", payload["scope"]
    titles = payload["groups"].sole["rows"].map { |row| row["title"] }
    assert_includes titles, "Open case"
  end

  test "search with chevron and members filters commands to Go to members" do
    titles = search_json(">members").fetch("groups").sole["rows"].map { |row| row["title"] }

    assert_equal ["Go to members"], titles
  end

  test "search commands with on_case return Resolve this case with case url" do
    kase = make_case(opened_at: 2.days.ago)
    get fd_search_path(format: :json), params: { q: ">", on_case: kase.id }
    rows = JSON.parse(response.body)["groups"].sole["rows"]

    resolve = rows.find { |row| row["title"] == "Resolve this case" }
    assert_equal "on case #{kase.id}", resolve["sub"]
    assert_equal fd_case_path(kase, do: "resolve"), resolve["url"]
  end

  test "search html page with q renders" do
    kase = make_case(opened_at: 2.days.ago)
    kase.update!(member_note: "a raid from six accounts")
    Fd::Note.create!(case_id: kase.id, body: "the raid again", author: "UFF1")

    get fd_search_path(q: "raid")

    assert_response :success
  end
end
