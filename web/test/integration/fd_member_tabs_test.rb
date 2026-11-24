require "test_helper"

class FdMemberTabsTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  MEMBER_ID = "UTABWHO".freeze
  OTHER_ID = "UTABOTHER".freeze

  setup do
    @boss = grant_role!("UTABBOSS", "community_manager")
    sign_in_as(@boss)
  end

  def slack!(actor:, entity: nil, action: "user_login", at: 1.hour.ago)
    id = SecureRandom.uuid
    as_pipeline(<<~SQL.squish, id, at, action, actor, entity, { id: id }.to_json)
      INSERT INTO slack.audit_event (id, at, action, actor_kind, actor_id, entity_kind, entity_id, ours, payload, source_key)
      VALUES (?::uuid, ?, ?, 'user', ?, 'user', ?, false, ?::jsonb, 'test')
    SQL
    seeded!("slack.audit_event", "id", id)
    id
  end

  def member_dim!(user_id, **columns)
    values = { invite_pending: false, claimed_at: nil, is_deleted: false }.merge(columns)
    as_pipeline("INSERT INTO raw.member_dim (user_id, invite_pending, claimed_at, is_deleted) VALUES (?, ?, ?, ?)",
      user_id, values[:invite_pending], values[:claimed_at], values[:is_deleted])
    seeded!("raw.member_dim", "user_id", user_id)
  end

  def tab_labels
    css_select("nav.member-record-tabs a.view").map { |link| link.at("span").text.squish }
  end

  test "member show renders the tab list with History current" do
    get fd_member_path(MEMBER_ID)

    assert_equal ["History", "Mentions", "Linked accounts", "Sessions", "Audit", "Enforcement", "Purges"], tab_labels
    assert_select "nav.member-record-tabs a[aria-current=true]", text: /History/
    assert_select "turbo-frame#member-record[target=_top]"
    assert_select %(nav.member-record-tabs a[href="#{fd_member_path(MEMBER_ID, tab: "audit")}"][data-turbo-frame="member-record"][data-turbo-action="advance"])
  end

  test "member show hides Linked accounts and Sessions without member.links and identity.read" do
    firefighter = grant_role!("UTABFF", "firefighter")
    override_capability!("firefighter", "member.links", false, by: "UTABBOSS")
    override_capability!("firefighter", "identity.read", false, by: "UTABBOSS")
    sign_in_as(firefighter)

    get fd_member_path(MEMBER_ID, tab: "sessions")

    assert_equal %w[History Mentions Audit Enforcement Purges], tab_labels
    assert_select "nav.member-record-tabs a[aria-current=true]", text: /History/
  end

  test "member show with do=links selects the Linked accounts tab" do
    get fd_member_path(MEMBER_ID, do: "links")

    assert_select "nav.member-record-tabs a[aria-current=true]", text: /Linked accounts/
    assert_select %(turbo-frame#member-links-#{MEMBER_ID}[src="#{fd_member_links_path(MEMBER_ID)}"][loading=lazy])
  end

  test "member audit tab lists events by and about the member linking to the audit log" do
    by_them = slack!(actor: MEMBER_ID)
    about_them = slack!(actor: OTHER_ID, entity: MEMBER_ID, action: "user_profile_updated", at: 2.hours.ago)
    slack!(actor: OTHER_ID, entity: "UTABNOBODY")

    get fd_member_path(MEMBER_ID, tab: "audit")

    search = { view: "everything", q: "about:#{MEMBER_ID} source:slack source:engine" }
    hrefs = css_select("a.member-audit-row").map { |link| link["href"] }
    assert_equal [fd_audit_path(search.merge(event: "slack:#{by_them}")), fd_audit_path(search.merge(event: "slack:#{about_them}"))], hrefs
    assert_select ".member-tab-head a[href=?]", fd_audit_path(search)
    assert_select ".member-tab-head .sub2", "2 events"
  end

  test "AuditQuery about: matches events by actor or entity" do
    slack!(actor: MEMBER_ID)
    slack!(actor: OTHER_ID, entity: MEMBER_ID)
    slack!(actor: OTHER_ID, entity: "UTABNOBODY")

    rows = Fd::AuditQuery.new({ "q" => "about:#{MEMBER_ID}", "view" => "everything" }, actor: @boss).rows

    assert_equal 2, rows.size
  end

  test "member enforcement tab lists active and lifted guards" do
    Fd::MemberGuard.create!(kind: "shush", subject_id: MEMBER_ID, opened_by: "UTABBOSS", reason: "spam in lounge",
      expires_at: 5.days.from_now)
    Fd::MemberGuard.create!(kind: "shush", subject_id: MEMBER_ID, opened_by: "UTABBOSS", reason: "old spam",
      opened_at: 40.days.ago, state: "lifted", lifted_at: 30.days.ago, lifted_by: "UTABBOSS")

    get fd_member_path(MEMBER_ID, tab: "enforcement")

    reasons = css_select(".member-tab table tbody tr").map { |row| row.css("td")[1].text.squish }
    assert_equal ["spam in lounge", "old spam"], reasons
    assert_select ".member-tab td", text: /\ALifted /
  end

  test "member enforcement tab leaves out lift-only deactivations" do
    Fd::MemberGuard.create!(kind: "deactivation", subject_id: MEMBER_ID, opened_by: "UTABBOSS",
      reason: "Deactivated outside Nemo", state: "lifting", enforced_by: "nemo", enforcement_status: "held",
      lift_only: true)

    get fd_member_path(MEMBER_ID, tab: "enforcement")

    assert_select ".member-tab .empty-title", "No guards"
  end

  test "member enforcement tab without guards renders the No guards title" do
    get fd_member_path(MEMBER_ID, tab: "enforcement")

    assert_select ".member-tab .empty-title", "No guards"
  end

  test "member show hero renders the invite pending and claimed account states" do
    member_dim!(MEMBER_ID, invite_pending: true)
    get fd_member_path(MEMBER_ID)
    assert_select ".member-hero-sub .state.state-warn", "Invite pending"

    member_dim!(OTHER_ID, claimed_at: 2.days.ago)
    get fd_member_path(OTHER_ID)
    assert_select ".member-hero-sub .state", "Claimed, no sign-in"
  end

  test "member show hero renders Active for a claimed account with a login" do
    member_dim!(MEMBER_ID, claimed_at: 2.days.ago)
    as_pipeline("INSERT INTO fd.member_seen (user_id, last_login_at) VALUES (?, now())", MEMBER_ID)
    seeded!("fd.member_seen", "user_id", MEMBER_ID)

    get fd_member_path(MEMBER_ID)

    assert_select ".member-hero-sub .state.state-good", "Active"
  end

  test "member show hero renders Deactivated from the live member row before the dim sync" do
    member_dim!(MEMBER_ID, claimed_at: 2.days.ago)
    member!(MEMBER_ID)
    as_pipeline("UPDATE fd.member SET is_deleted = true WHERE user_id = ?", MEMBER_ID)
    as_pipeline("INSERT INTO fd.member_seen (user_id, last_login_at) VALUES (?, now())", MEMBER_ID)
    seeded!("fd.member_seen", "user_id", MEMBER_ID)

    get fd_member_path(MEMBER_ID)

    assert_select ".member-hero-sub .state", "Deactivated"
  end

  test "member show hero renders Active from the live member row after a reactivation before the dim sync" do
    member_dim!(MEMBER_ID, claimed_at: 2.days.ago, is_deleted: true)
    member!(MEMBER_ID)
    as_pipeline("INSERT INTO fd.member_seen (user_id, last_login_at) VALUES (?, now())", MEMBER_ID)
    seeded!("fd.member_seen", "user_id", MEMBER_ID)

    get fd_member_path(MEMBER_ID)

    assert_select ".member-hero-sub .state.state-good", "Active"
  end

  test "member show hero renders no state for an account claimed before sign-in recording" do
    member_dim!(MEMBER_ID, claimed_at: Time.utc(2024, 1, 1))

    get fd_member_path(MEMBER_ID)

    assert_select ".member-hero-sub .state", false
  end
end
