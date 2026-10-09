require "test_helper"

class FdAuditPivotsTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  WHO = "UPIVWHO".freeze
  AT = Time.utc(2026, 9, 29, 15, 37, 20)

  setup do
    hold_role!("UPIVBOSS", "community_manager")
    @ff = hold_role!("UPIVFF", "firefighter")
    sign_in_as(@ff)
  end

  def slack!(action: "user_channel_join", actor: WHO, at: AT, session: 4242, channel: "C0PIVROOM", app: "A0PIVAPP1")
    id = SecureRandom.uuid
    payload = { id: id, action: action, context: { ip_address: "81.2.69.144", session_id: session } }
    as_pipeline(<<~SQL.squish, id, at, action, actor, actor, channel, app, session, payload.to_json)
      INSERT INTO slack.audit_event (id, at, action, actor_kind, actor_id, entity_kind, entity_id, ours,
                                     ip, channel_id, app_id, session_id, payload, source_key)
      VALUES (?::uuid, ?, ?, 'user', ?, 'user', ?, false, '81.2.69.144'::inet, ?, ?, ?, ?::jsonb, 'test')
    SQL
    seeded!("slack.audit_event", "id", id)
    id
  end

  def slim!(at:, session:, actor: WHO)
    id = SecureRandom.uuid
    as_pipeline(<<~SQL.squish, id, at, actor, session)
      INSERT INTO slack.audit_view (id, at, action, actor_id, object_id, ip, session_id, ours)
      VALUES (?::uuid, ?, 3, ?, 'F0PIVFILE', '81.2.69.144'::inet, ?, false)
    SQL
    seeded!("slack.audit_view", "id", id)
  end

  def menu_links
    css_select("tr.audit-row .menu-pop a").to_h { |one| [one.text.squish, one["href"]] }
  end

  test "each row offers a pivot for every value it has, and still opens the full event in one click" do
    id = slack!

    get fd_audit_path(q: "after:2026-09-01")
    assert_equal ["Same actor", "Same action", "Same address", "Same app",
                  "Same actor within 15 minutes", "Same session"], menu_links.keys
    assert_select "tr.audit-row a.audit-more[data-turbo-frame=audit-panel][href=?]",
      fd_audit_event_path(source: "slack", id: id)
  end

  test "a channel pivot is only offered for a channel we can name" do
    slack!
    as_pipeline("INSERT INTO raw.channel_dim (channel_id, name, visibility) VALUES ('C0PIVROOM', 'pivot-room', 'public')")
    seeded!("raw.channel_dim", "channel_id", "C0PIVROOM")

    get fd_audit_path(q: "after:2026-09-01")
    assert_equal fd_audit_path(q: "after:2026-09-01 channel:C0PIVROOM"), menu_links["Same channel"]
  end

  test "a value pivot swaps that term and keeps the rest of the search" do
    slack!

    get fd_audit_path(q: "after:2026-09-01 action:user_channel_join")
    links = menu_links
    assert_nil links["Same action"]
    assert_equal fd_audit_path(q: "after:2026-09-01 action:user_channel_join actor:#{WHO}"), links["Same actor"]
    assert_equal fd_audit_path(q: "after:2026-09-01 action:user_channel_join app:A0PIVAPP1"), links["Same app"]
  end

  test "around an event starts a fresh search on that actor, 15 minutes either side, views included" do
    slack!
    slim!(at: AT + 10.minutes, session: 9999)
    slim!(at: AT + 40.minutes, session: 9999)
    slack!(actor: "UPIVOTHER", at: AT + 1.minute)

    get fd_audit_path(q: "after:2026-09-01 action:user_channel_join")
    href = menu_links["Same actor within 15 minutes"]
    assert_equal fd_audit_path(q: "actor:#{WHO} after:2026-09-29T15:22 before:2026-09-29T15:53 show:high_volume"), href

    get href
    assert_equal 2, css_select("tr.audit-row").size
  end

  test "the same session finds that session's events and views" do
    slack!
    slim!(at: AT + 2.hours, session: 4242)
    slim!(at: AT + 2.hours, session: 9999)

    get fd_audit_path(q: "after:2026-09-01")
    href = menu_links["Same session"]
    assert_equal fd_audit_path(q: "actor:#{WHO} session:4242 show:high_volume"), href

    get href
    assert_equal 2, css_select("tr.audit-row").size
  end

  test "no address pivot without identity.read" do
    slack!
    move_capability!("firefighter", "identity.read", false, by: "UPIVBOSS")

    get fd_audit_path(q: "after:2026-09-01")
    assert_nil menu_links["Same address"]
    assert menu_links["Same actor"]
  end

  test "an event with no payload still opens in the drawer" do
    id = SecureRandom.uuid
    as_pipeline(<<~SQL.squish, id, AT)
      INSERT INTO slack.audit_event (id, at, action, actor_kind, actor_id, ours, payload, source_key)
      VALUES (?::uuid, ?, 'user_login', 'user', 'UPIVBARE', false, '{}'::jsonb, 'test')
    SQL
    seeded!("slack.audit_event", "id", id)

    get fd_audit_path(q: "after:2026-09-01")
    assert_select "tr.audit-row a.audit-more[href=?]", fd_audit_event_path(source: "slack", id: id)

    get fd_audit_event_path(source: "slack", id: id)
    assert_response :success
    assert_select ".audit-panel-raw", count: 0
    assert_select ".audit-pivots a.chip", text: "Same actor"
  end

  test "the drawer carries the same pivots" do
    id = slack!

    get fd_audit_event_path(source: "slack", id: id)
    assert_select ".audit-pivots a.chip", text: "Same session"
    assert_select ".audit-pivots a.chip[href=?]", fd_audit_path(q: "actor:#{WHO}")
  end
end
