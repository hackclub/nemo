require "test_helper"

class FdAuditFiltersTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def slack!(action, category)
    id = SecureRandom.uuid
    as_pipeline(<<~SQL.squish, id, action, category)
      INSERT INTO slack.audit_event (id, at, action, category, actor_kind, actor_id, ours, payload, source_key)
      VALUES (?::uuid, now() - interval '1 hour', ?, ?, 'user', 'UFILTER', false, '{}', 'test')
    SQL
    seeded!("slack.audit_event", "id", id)
  end

  def slim!(code)
    id = SecureRandom.uuid
    as_pipeline("INSERT INTO slack.audit_view (id, at, action, actor_id, object_id) " \
                "VALUES (?::uuid, now() - interval '2 hours', ?, 'UFILTER', 'F0FILE')", id, code)
    seeded!("slack.audit_view", "id", id)
  end

  def query(term, view: "everything")
    Fd::AuditQuery.new({ "view" => view, "q" => term }, actor: @me)
  end

  test "a category keeps the slack events in it and nothing from the other logs" do
    slack!("user_login", "sign_ins")
    slack!("channel_created", "channels")
    Fd::AuditEntry.create!(occurred_at: 1.hour.ago, actor_user_id: "UME", actor_kind: "human",
      entity_type: "case", entity_id: 1, verb: "opened", source_app: "fire_engine")

    rows = query("category:sign_ins").rows
    assert_equal %w[user_login], rows.map(&:verb)
  end

  test "a category can be named by its label" do
    term = Fd::AuditSearch.parse("category:Huddles").terms.first
    assert_equal ["category", "huddles", "Huddles"], [term.kind, term.value, term.label]
    assert_empty Fd::AuditSearch.parse("category:nonsense").terms
  end

  test "picking a filter replaces the one of its kind and keeps the rest" do
    held = query("category:people did:user_login @UFILTER", view: "slack")

    params = held.set_params("category", "channels")
    assert_equal "action:user_login about:UFILTER category:channels", params["q"]
    assert_equal({ "q" => "action:user_login about:UFILTER" }, held.set_params("category"))
  end

  test "the filter row lists each category and narrows the actions to the one picked" do
    get fd_audit_path(q: "category:huddles")
    assert_response :success

    assert_select ".audit-filters summary", text: /Category\s*Huddles/
    assert_select ".audit-filters .menu-group", 1
    assert_select ".audit-filters .menu-group", "Huddles"
    assert_select ".audit-filters a[aria-current='true']", text: "Huddles"
  end

  test "the time presets and the doer filter write the terms the search already reads" do
    get fd_audit_path
    week = 7.days.ago.to_date.iso8601

    assert_select ".audit-filters .daterange a[href*='after%3A#{week}']", "Last 7 days"
    assert_select ".audit-filters .daterange form[action='#{fd_audit_path}']"
    assert_select ".audit-filters a[href*='is%3Ahuman']", "A person"

    get fd_audit_path(q: "after:#{week}")
    assert_select ".audit-filters .daterange-presets summary", text: /Last 7 days/
  end

  test "a range picked on the calendar becomes after and before, the end day included" do
    get fd_audit_path(q: "did:user_login after:2026-01-01", start: "2026-10-01", end: "2026-10-03")

    assert_redirected_to fd_audit_path(q: "action:user_login after:2026-10-01 before:2026-10-04")
    follow_redirect!
    assert_select ".audit-filters .daterange-presets summary", text: /Custom/
    assert_select ".daterange-open", text: /Oct 1 - Oct 3, 2026/
  end

  test "high-volume actions stay hidden until shown, and then all four kinds come" do
    slack!("user_login", "sign_ins")
    slim!(3)
    slim!(4)
    slim!(2)

    assert_equal %w[user_login], query("", view: "slack").rows.map(&:verb)

    shown = query("show:high_volume", view: "slack").rows.map(&:verb)
    assert_equal %w[canvas_opened file_downloaded list_cell_updated user_login], shown.sort
  end

  test "a category narrows the high-volume actions too" do
    slim!(3)
    slim!(4)
    slim!(2)

    rows = query("show:high_volume category:canvases_and_lists", view: "slack").rows
    assert_equal %w[canvas_opened list_cell_updated], rows.map(&:verb).sort
  end

  test "the toggle shows which way it is set and flips the term" do
    get fd_audit_path
    assert_select ".audit-filters summary", text: /High-volume\s*Hidden/
    assert_select ".audit-filters a[href*='show%3Ahigh_volume']", "Shown"

    get fd_audit_path(q: "show:high_volume")
    assert_select ".audit-filters summary", text: /High-volume\s*Shown/
    assert_select ".audit-chips .chip", text: /high-volume actions/
  end
end
