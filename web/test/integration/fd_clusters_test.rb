require "test_helper"

class FdClustersTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  ROOT = "UCROOT".freeze
  ALT = "UCALT".freeze
  GONE = "UCGONE".freeze

  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
    [ROOT, ALT, GONE].each_with_index do |user_id, at|
      member!(user_id)
      cluster!(user_id, ROOT, active: user_id != GONE)
      joined!(user_id, (3 - at).days.ago)
    end
    as_pipeline("UPDATE fd.member SET is_deleted = true WHERE user_id = ?", GONE)
    link!(ROOT, ALT, 9.5)
    link!(ALT, GONE, 6.0)
    sighting!(ROOT, "81.2.69.144", 2.days.ago)
    sighting!(ALT, "81.2.69.144", 2.days.ago)
    sighting!(GONE, "10.9.9.9", 1.day.ago)
    snapshot!(GONE)
  end

  test "a cluster page draws every account and the links between them" do
    get fd_cluster_path(ROOT)
    assert_response :success

    assert_select ".cluster-map a.node", 3
    assert_select ".cluster-map line.edge-certain", 1
    assert_select ".cluster-map line.edge-strong", 1
    assert_select ".cluster-map a.node-gone", 1
    assert_select "table.data-table tbody tr", minimum: 3
  end

  test "every account on the map shows its face and opens the member" do
    get fd_cluster_path(ROOT)

    [ROOT, ALT, GONE].each do |user_id|
      assert_select ".cluster-map a.node[href='#{fd_member_path(user_id)}'][data-turbo-frame='person-drawer']" do
        assert_select "image[href$='/#{user_id}/r']"
        assert_select "text.node-name"
      end
    end
  end

  test "the sessions show which address the accounts shared" do
    get fd_cluster_path(ROOT)

    assert_select ".cluster-cells i.shared", 2
    assert_select ".cluster-cells i.own", 1
    assert_match "81.2.69.144", response.body
    legend = css_select(".cluster-map-key").map(&:text).join
    assert_includes legend, "81.2.69.144"
    assert_not_includes legend, "10.9.9.9", "an address one account used alone is not listed as shared"
  end

  test "the evidence frozen at deactivation is shown" do
    get fd_cluster_path(ROOT)

    assert_select "h2", "Evidence at deactivation"
    assert_match "ban evasion", response.body
    assert_match "1 trait, 1 link", response.body
  end

  test "reading a cluster is logged for every account in it" do
    assert_difference -> { AccessLog.where(field_class: "links", subject_user_id: [ROOT, ALT, GONE]).count }, 3 do
      get fd_cluster_path(ROOT)
    end
    assert_equal 3, AccessLog.where(field_class: "login", subject_user_id: [ROOT, ALT, GONE]).count
  end

  test "without identity.read the addresses and snapshots stay hidden" do
    move_capability!("firefighter", "identity.read", false, by: "UME")
    sign_in_as(hold_role!("UFF", "firefighter"))

    get fd_cluster_path(ROOT)
    assert_response :success
    assert_select "h2", text: "Sessions", count: 0
    assert_select "h2", text: "Evidence at deactivation", count: 0
    assert_no_match "81.2.69.144", response.body
  end

  test "a case can be opened about the whole cluster" do
    get fd_cluster_path(ROOT)

    href = css_select("a.btn-primary").find { |one| one.text.include?("Open a case") }["href"]
    [ROOT, ALT, GONE].each { |user_id| assert_includes CGI.unescape(href), "subject_user_ids[]=#{user_id}" }
  end

  test "deactivating from a cluster opens a guard per active account and comes back here" do
    get fd_cluster_path(ROOT)
    assert_select ".modal-host[data-modal-id-value='cluster-deactivate'] input[name='user_ids[]']", 2

    assert_difference -> { Fd::MemberGuard.where(kind: "deactivation").count }, 2 do
      post fd_bulk_deactivations_path, params: { user_ids: [ROOT, ALT], reason: "ring", cluster_id: ROOT }
    end
    assert_redirected_to fd_cluster_path(ROOT)
  end

  test "an unknown cluster is not found" do
    get fd_cluster_path("UNOBODY")
    assert_response :not_found
  end

  test "the clusters tab and a member pane both lead to the cluster" do
    get fd_links_path(view: "clusters")
    assert_select "a[href='#{fd_cluster_path(ROOT)}']"

    get fd_member_links_path(ALT)
    assert_select "a[href='#{fd_cluster_path(ROOT)}']", "Open cluster"
  end

  private

  def cluster!(user_id, cluster_id, active:)
    as_pipeline("INSERT INTO fd.member_cluster (user_id, cluster_id, accounts, ring, active) VALUES (?, ?, 3, false, ?)",
      user_id, cluster_id, active)
    seeded!("fd.member_cluster", "user_id", user_id)
  end

  def joined!(user_id, at)
    as_pipeline("INSERT INTO fd.member_joins (user_id, joined_at, source) VALUES (?, ?, 'team_join') " \
                "ON CONFLICT (user_id) DO NOTHING", user_id, at)
    seeded!("fd.member_joins", "user_id", user_id)
  end

  def link!(one, two, score)
    a, b = [one, two].sort
    as_pipeline("INSERT INTO fd.member_link (a_user_id, b_user_id, score, top_signal) VALUES (?, ?, ?, 'ip_stable')",
      a, b, score)
    seeded!("fd.member_link", "a_user_id", a)
  end

  def sighting!(user_id, ip, at)
    as_pipeline(<<~SQL.squish, user_id, at, ip, at, at)
      INSERT INTO fd.login_event (user_id, source, hour, ip, first_at, last_at)
      VALUES (?, 'audit_logs', date_trunc('hour', ?::timestamptz, 'UTC'), ?::inet, ?, ?)
    SQL
    seeded!("fd.login_event", "user_id", user_id)
    seeded!("fd.member_trait", "user_id", user_id)
    seeded!("fd.member_touch", "user_id", user_id)
  end

  def snapshot!(user_id)
    as_pipeline(<<~SQL.squish, user_id)
      INSERT INTO fd.evidence_snapshot (user_id, deactivated_at, source, actor_id, reason, identity, traits, links)
      VALUES (?, now() - interval '1 day', 'fire_engine', 'UME', 'ban evasion', '{}',
              '[{"kind": "ip", "value": "10.9.9.9"}]', '[{"other": "UCALT", "score": 6.0}]')
    SQL
    seeded!("fd.evidence_snapshot", "user_id", user_id)
  end
end
