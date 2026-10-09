require "test_helper"

class FdAuditZoneTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  AT = Time.utc(2026, 10, 1, 2, 30)

  setup do
    @me = hold_role!("UZONEME", "community_manager")
    sign_in_as(@me)
    member!("UZONEME")
    @id = slack!
  end

  def slack!(at: AT)
    id = SecureRandom.uuid
    as_pipeline(<<~SQL.squish, id, at, { id: id, action: "user_login" }.to_json)
      INSERT INTO slack.audit_event (id, at, action, actor_kind, actor_id, entity_kind, entity_id,
                                     ours, payload, source_key)
      VALUES (?::uuid, ?, 'user_login', 'user', 'UZONEWHO', 'user', 'UZONEWHO', false, ?::jsonb, 'test')
    SQL
    seeded!("slack.audit_event", "id", id)
    id
  end

  def lives_in!(tz)
    as_pipeline("UPDATE fd.member SET tz = ? WHERE user_id = 'UZONEME'", tz)
  end

  def when_cell
    css_select("td.audit-when time").first
  end

  test "rows read in the viewer's slack timezone" do
    lives_in!("America/New_York")

    get fd_audit_path
    assert_equal "30 Sep 22:30", when_cell.text.squish
    assert_equal "1 Oct 2026 02:30:00 UTC", when_cell["title"]
  end

  test "the drawer gives the local time and utc" do
    lives_in!("America/New_York")

    get fd_audit_event_path(source: "slack", id: @id)
    assert_select ".fact", text: /When\s+30 Sep 2026 22:30:00 EDT/
    assert_select ".fact", text: /UTC\s+1 Oct 2026 02:30:00/
  end

  test "dates in a search are the viewer's days" do
    lives_in!("America/New_York")

    get fd_audit_path(q: "after:2026-10-01")
    assert_select "td.audit-when", count: 0

    get fd_audit_path(q: "after:2026-09-30 before:2026-10-01")
    assert_select "td.audit-when", count: 1

    get fd_audit_path(on: "2026-09-30")
    assert_select "td.audit-when", count: 1
  end

  test "somebody with no slack timezone reads utc" do
    get fd_audit_path
    assert_equal "1 Oct 02:30", when_cell.text.squish

    get fd_audit_event_path(source: "slack", id: @id)
    assert_select ".fact dt", text: "UTC", count: 0
    assert_select ".fact", text: /When\s+1 Oct 2026 02:30:00 UTC/
  end
end
