require "test_helper"

class FdAuditAccessTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  WHO = "UAUDWHO".freeze
  IP = "81.2.69.144".freeze
  EMAIL = "kid@alts.example".freeze

  setup do
    hold_role!("UBOSS", "community_manager")
    @ff = hold_role!("UFFAUD", "firefighter")
    sign_in_as(@ff)
  end

  def slack!(action: "user_login", actor: WHO, at: 1.hour.ago)
    id = SecureRandom.uuid
    as_pipeline(<<~SQL.squish, id,
      INSERT INTO slack.audit_event (id, at, action, actor_kind, actor_id, actor_email,
                                     entity_kind, entity_id, ours, ip, payload, source_key)
      VALUES (?::uuid, ?, ?, 'user', ?, ?, 'user', ?, false, ?::inet, ?::jsonb, 'test')
    SQL
      at, action, actor, EMAIL, actor, IP,
      { id: id, action: action, context: { ip_address: IP },
        actor: { type: "user", user: { id: actor, email: EMAIL, name: "kid" } },
        entity: { type: "file", file: { title: EMAIL } } }.to_json)
    seeded!("slack.audit_event", "id", id)
    id
  end

  def logged(field_class)
    AccessLog.where(actor_id: @ff.user_id, field_class: field_class).pluck(:subject_user_id)
  end

  test "a firefighter reads slack events through audit.read" do
    slack!

    get fd_audit_path
    assert_response :success
    assert_select ".view[aria-current=true]", /Slack/
    assert_match(/user login/, response.body)
    assert_select ".audit-filters", text: /Category/
  end

  test "without audit.read the slack tab, its rows and its filters are gone" do
    slack!
    move_capability!("firefighter", "audit.read", false, by: "UBOSS")

    get fd_audit_path
    assert_response :success
    assert_select ".view", text: /Slack/, count: 0
    assert_select ".view[aria-current=true]", /Everything/
    assert_no_match(/user login/, response.body)
    assert_select ".audit-filters", text: /Category/, count: 0
    assert_select ".audit-filters", text: /High-volume/, count: 0

    get fd_audit_path(view: "slack", q: "source:slack")
    assert_no_match(/user login/, response.body)
  end

  test "a slack event drawer is refused without audit.read" do
    id = slack!
    move_capability!("firefighter", "audit.read", false, by: "UBOSS")

    get fd_audit_event_path(source: "slack", id: id)
    assert_response :forbidden
  end

  test "the audit log shows in the nav for audit.read alone" do
    get fd_cases_path
    assert_select "a[href='#{fd_audit_path}']"

    move_capability!("firefighter", "audit.read", false, by: "UBOSS")
    get fd_cases_path
    assert_select "a[href='#{fd_audit_path}']", count: 0
  end

  test "addresses and emails are hidden without identity.read" do
    id = slack!
    move_capability!("firefighter", "identity.read", false, by: "UBOSS")

    get fd_audit_path
    assert_match(/user login/, response.body)
    assert_no_match(IP, response.body)
    assert_no_match(EMAIL, response.body)

    get fd_audit_event_path(source: "slack", id: id)
    assert_response :success
    assert_no_match(IP, response.body)
    assert_no_match(EMAIL, response.body)
    assert_select "dt", text: "Address", count: 0
    assert_match(/hidden/, response.body)
    assert_match(/kid/, response.body)
  end

  test "addresses and emails show with identity.read" do
    id = slack!

    get fd_audit_event_path(source: "slack", id: id)
    assert_match(IP, response.body)
    assert_match(EMAIL, response.body)
  end

  test "an address or email search is refused without identity.read and logs nothing" do
    slack!
    move_capability!("firefighter", "identity.read", false, by: "UBOSS")

    [IP, EMAIL, "domain:alts.example", "text:#{IP}"].each do |asked|
      get fd_audit_path(q: asked)
      assert_response :success
      assert_select ".empty-title", "Not yours to search by address or email"
      assert_no_match(/user login/, response.body)
    end
    assert_empty logged("identity_search")
  end

  test "an address search logs the people it showed" do
    slack!
    slack!(actor: "UAUDOTHER")

    get fd_audit_path(q: IP)
    assert_match(/user login/, response.body)
    assert_equal [WHO, "UAUDOTHER"].sort, logged("identity_search").sort

    get fd_audit_path(q: "invite spam")
    assert_equal 2, logged("identity_search").size
  end

  test "a slack search about somebody logs them" do
    slack!

    get fd_audit_path(q: "actor:#{WHO}")
    assert_equal [WHO], logged("audit")

    get fd_audit_path
    assert_equal [WHO], logged("audit")
  end

  test "a search about somebody outside slack does not log a slack read" do
    get fd_audit_path(view: "reads", q: "about:#{WHO}")
    assert_empty logged("audit")
  end
end
