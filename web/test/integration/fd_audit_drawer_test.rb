require "test_helper"

class FdAuditDrawerTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  WHO = "UDRAWWHO".freeze
  AT = Time.utc(2026, 9, 29, 15, 37, 20)
  UA = "Mozilla/5.0 (Macintosh) Slack/4.41 drawer-test".freeze

  setup do
    hold_role!("UDRAWBOSS", "community_manager")
    @ff = hold_role!("UDRAWFF", "firefighter")
    sign_in_as(@ff)
    @ua = as_pipeline_value("INSERT INTO slack.user_agent (ua, app, os) VALUES (?, 'Slack desktop', 'macOS') " \
                            "ON CONFLICT (md5(ua)) DO UPDATE SET app = EXCLUDED.app RETURNING id", UA)
    as_pipeline("INSERT INTO fd.ip_network (ip_prefix, asn, network, country, class, source) " \
                "VALUES ('81.2.69.0/24', 64500, 'Example Net', 'GB', 'stable', 'ipinfo') ON CONFLICT DO NOTHING")
    seeded!("fd.ip_network", "ip_prefix", "81.2.69.0/24")
  end

  def as_pipeline_value(sql, *binds)
    as_pipeline(sql, *binds).first.values.first
  end

  def slack!(action: "user_login", at: AT, actor: WHO, payload: nil)
    id = SecureRandom.uuid
    payload ||= {
      id: id, action: action,
      actor: { type: "user", user: { id: actor, name: "Kid Realname", email: "kid@alts.example" } },
      entity: { type: "file", file: { id: "F0DRAW", name: "plans.pdf" } },
      context: { ip_address: "81.2.69.144", session_id: 4242, app: { id: "A0DRAWAPP", name: "Toolbox" } }
    }
    as_pipeline(<<~SQL.squish, id, at, action, actor, @ua, payload.to_json)
      INSERT INTO slack.audit_event (id, at, action, actor_kind, actor_id, entity_kind, entity_id, ours,
                                     ip, ua_id, app_id, session_id, payload, source_key)
      VALUES (?::uuid, ?, ?, 'user', ?, 'file', 'F0DRAW', false, '81.2.69.144'::inet, ?, 'A0DRAWAPP', 4242,
              ?::jsonb, 'test')
    SQL
    seeded!("slack.audit_event", "id", id)
    id
  end

  def fact(label)
    css_select(".audit-panel-facts .fact").find { |one| one.at_css("dt")&.text == label }&.at_css("dd")&.text&.squish
  end

  test "the drawer lays the event out as fields, with the raw event folded" do
    id = slack!

    get fd_audit_event_path(source: "slack", id: id)
    assert_response :success
    assert_equal "Slack · Sign-ins and security", fact("Log")
    assert_match "kid@alts.example", fact("Actor")
    assert_match "plans.pdf", fact("Entity")
    assert_equal "81.2.69.144", fact("Address")
    assert_equal "GB · Example Net stable", fact("Location")
    assert_equal "Slack desktop · macOS", fact("Device")
    assert_equal "4242", fact("Session")
    assert_equal "Toolbox A0DRAWAPP", fact("App")
    assert_select "details.audit-panel-rawbox:not([open]) > summary", "Raw event"
    assert_select "details.audit-panel-rawbox pre", /Kid Realname/
  end

  test "without identity.read the email, address, location and real names stay out" do
    id = slack!
    move_capability!("firefighter", "identity.read", false, by: "UDRAWBOSS")

    get fd_audit_event_path(source: "slack", id: id)
    assert_nil fact("Address")
    assert_nil fact("Location")
    assert_no_match "kid@alts.example", response.body
    assert_no_match "Kid Realname", response.body
    assert_equal "Slack desktop · macOS", fact("Device")
    assert_match "plans.pdf", fact("Entity")
  end

  test "related events are the same actor within 15 minutes, each opening in the drawer" do
    id = slack!
    near = slack!(action: "user_logout", at: AT + 5.minutes)
    slack!(action: "user_logout", at: AT + 40.minutes)
    slack!(actor: "UDRAWOTHER", at: AT + 1.minute)

    get fd_audit_event_path(source: "slack", id: id)
    links = css_select(".audit-related a.audit-related-row")
    assert_equal [fd_audit_event_path(source: "slack", id: near)], links.map { |one| one["href"] }
    assert_select ".audit-related-all", count: 0
  end

  test "a busy quarter hour links to all of it" do
    id = slack!
    11.times { |n| slack!(at: AT + (n + 1).minutes) }

    get fd_audit_event_path(source: "slack", id: id)
    assert_select ".audit-related a.audit-related-row", 10
    assert_select ".audit-related-all[href*='session'], .audit-related-all[href*='after']", 1
  end

  test "an event with nothing extra still shows what it has" do
    id = slack!(payload: {})

    get fd_audit_event_path(source: "slack", id: id)
    assert_response :success
    assert_equal "Slack · Sign-ins and security", fact("Log")
    assert_select "details.audit-panel-rawbox", count: 0
  end
end
