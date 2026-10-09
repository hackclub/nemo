require "test_helper"

class FdAuditGroupsTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  setup do
    hold_role!("UGRPBOSS", "community_manager")
    @ff = hold_role!("UGRPFF", "firefighter")
    sign_in_as(@ff)
  end

  def slack!(actor: "UGRPONE", action: "user_login", at: 1.hour.ago, ip: "81.2.69.144", app: nil, channel: nil)
    id = SecureRandom.uuid
    payload = { id: id, action: action, context: { ip_address: ip, app: ({ id: app, name: "Toolbox" } if app) }.compact }
    as_pipeline(<<~SQL.squish, id, at, action, actor, actor, ip, app, channel, payload.to_json)
      INSERT INTO slack.audit_event (id, at, action, actor_kind, actor_id, entity_kind, entity_id,
                                     ours, ip, app_id, channel_id, payload, source_key)
      VALUES (?::uuid, ?, ?, 'user', ?, 'user', ?, false, ?::inet, ?, ?, ?::jsonb, 'test')
    SQL
    seeded!("slack.audit_event", "id", id)
  end

  def cells
    css_select(".audit-groups tbody tr").map { |row| row.css("td").map { |cell| cell.text.squish } }
  end

  test "grouping by actor counts each one with first and last seen, busiest first" do
    slack!(actor: "UGRPONE", at: 3.hours.ago)
    slack!(actor: "UGRPTWO", at: 2.hours.ago)
    slack!(actor: "UGRPTWO", at: 1.hour.ago)

    get fd_audit_path(group: "actor")
    assert_response :success
    assert_select ".audit-groups th", "Actor"
    assert_equal [%w[@UGRPTWO 2], %w[@UGRPONE 1]], cells.map { |one| one.first(2) }
    assert_select ".audit-groups tbody tr td.audit-when time", minimum: 4
    assert_select ".pager-at", /of \d+ actors?/
    assert_select ".audit-table:not(.audit-groups)", count: 0
  end

  test "a group's count opens its events without the grouping" do
    slack!(actor: "UGRPTWO")

    get fd_audit_path(group: "actor", q: "last:7d")
    link = css_select(".audit-groups td.col-num a").first
    assert_equal fd_audit_path(q: "last:7d actor:UGRPTWO"), link["href"]
  end

  test "apps group under their name and filter by app:" do
    slack!(app: "A0GRPAPP1")
    slack!(app: "A0GRPAPP1", action: "user_logout")
    slack!

    get fd_audit_path(group: "app")
    assert_equal [["Toolbox", "2"]], cells.map { |one| one.first(2) }

    get fd_audit_path(q: "app:A0GRPAPP1")
    assert_equal 2, css_select("tr.audit-row").size
  end

  test "channels and actions group too" do
    slack!(action: "user_channel_join", channel: "C0GRPROOM")
    slack!(action: "user_channel_join", channel: "C0GRPROOM")

    get fd_audit_path(group: "action")
    assert_includes cells.map(&:first), "Joined a channel"

    get fd_audit_path(group: "channel")
    assert_equal "2", cells.find { |one| one.first.present? }&.second
  end

  test "the grouping stays while filters and tabs change" do
    get fd_audit_path(group: "actor")

    assert_select ".audit-filters a[href*='group=actor'][href*='last%3A7d']", "Last 7 days"
    assert_select ".view[href*='group=actor']", minimum: 1
    assert_select ".audit-filters a[href='#{fd_audit_path}']", "None"
  end

  test "addresses only group for identity.read" do
    slack!

    get fd_audit_path(group: "address")
    assert_select ".audit-groups th", "Address"
    assert_includes cells.map(&:first), "81.2.69.144"

    move_capability!("firefighter", "identity.read", false, by: "UGRPBOSS")
    get fd_audit_path(group: "address")
    assert_select ".audit-groups", count: 0
    assert_select ".audit-filters a", text: "Address", count: 0
    assert_no_match "81.2.69.144", response.body
  end
end
