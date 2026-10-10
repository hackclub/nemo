require "test_helper"

class FdMemberLinksTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  test "the links page opens" do
    get fd_links_path
    assert_response :success
  end

  test "the links page listens for changes and reloads its own list" do
    get fd_links_path(over: "strong")

    assert_select "turbo-cable-stream-source"
    assert_select %(turbo-frame##{Fd::MemberLinkBroadcast::LIST_FRAME}[data-src="#{fd_links_path(over: "strong")}"])
  end

  test "a member page listens for changes to that member's links" do
    member!("UONE")
    get fd_member_path("UONE")

    assert_select "turbo-cable-stream-source", minimum: 2
    assert_select %(turbo-frame#member-links-UONE)
  end

  test "a member link pane reads the links" do
    member!("UONE")
    member!("UTWO")
    link!("UONE", "UTWO", score: 9.5, top: "ip_exact",
      signals: '{"ip_exact": {"value": "1.2.3.4", "people": 2, "score": 5.0}}')

    get fd_member_links_path("UONE")
    assert_response :success
    assert_match "UTWO", response.body

    links = Fd::MemberLink.for_member("UONE")
    assert_equal 1, links.size
    assert_equal "UTWO", links.first.other_id
    assert links.first.certain?
    assert_equal "certain", links.first.band
  end

  test "a link is found from either side" do
    member!("UONE")
    member!("UTWO")
    link!("UONE", "UTWO", score: 3.0, top: "ip_prefix")

    assert_equal ["UTWO"], Fd::MemberLink.for_member("UONE").map(&:other_id)
    assert_equal ["UONE"], Fd::MemberLink.for_member("UTWO").map(&:other_id)
  end

  test "the bands are read off the score" do
    member!("UONE")
    member!("UTWO")
    link!("UONE", "UTWO", score: 3.0, top: "ip_prefix")

    assert_equal "worth a look", Fd::MemberLink.for_member("UONE").first.band
  end

  test "somebody without member.links is handed nothing" do
    move_capability!("firefighter", "member.links", false, by: "UME")
    sign_in_as(hold_role!("UFF", "firefighter"))

    get fd_links_path
    assert_response :redirect
  end

  test "the page opens on strong links to a deactivated account nobody has judged yet" do
    member!("UACTIVE")
    member!("UGONE")
    member!("UJUDGED")
    member!("UWEAK")
    member!("UBOTHON")
    gone!("UGONE")
    gone!("UJUDGED")
    gone!("UWEAK")
    link!("UACTIVE", "UGONE", score: 9.5, top: "mailbox_alias",
      signals: '{"mailbox_alias": {"value": "kid@gmail.com", "people": 2, "score": 8.0}}')
    link!("UACTIVE", "UJUDGED", score: 9.0, top: "ip_stable")
    link!("UACTIVE", "UWEAK", score: 3.5, top: "ip_prefix_stable")
    link!("UACTIVE", "UBOTHON", score: 9.0, top: "ip_stable")
    verdict!("UACTIVE", "UJUDGED", "different_people")

    get fd_links_path
    assert_response :success

    assert_select ".view[aria-current=true]", "Needs review"
    rows = css_select("tbody tr")
    assert_equal 1, rows.size
    assert_match(/ugone/i, rows.first.text)
    assert_match "Same mailbox, once dots and plus tags are removed", rows.first.text
    assert_match "kid@gmail.com", rows.first.text
  end

  test "the clusters tab lists each cluster with its flags" do
    cluster!("UOLD", "UOLD", accounts: 3, active: true, ring: true)
    cluster!("UNEW", "UOLD", accounts: 3, active: false, ring: true)
    cluster!("UMID", "UOLD", accounts: 3, active: true, ring: true, conflict: true)

    get fd_links_path(view: "clusters")
    assert_response :success

    row = css_select("tbody tr").find { |one| one.text.include?("UOLD") }
    assert_match(/3\s+2/, row.text.squish)
    assert_match "Ring", row.text
    assert_match "Conflict", row.text
  end

  test "all pairs keeps the band filter and shows the reasons" do
    member!("UONE")
    member!("UTWO")
    member!("UTHREE")
    link!("UONE", "UTWO", score: 9.5, top: "ip_stable",
      signals: '{"ip_stable": {"value": "81.2.69.144", "people": 2, "score": 5.0}}')
    link!("UONE", "UTHREE", score: 3.5, top: "ip_prefix_stable")

    get fd_links_path(view: "pairs", over: "certain")
    assert_response :success

    assert_select ".segmented a[aria-current=true]", "Certain"
    assert_equal 1, css_select("tbody tr").size
    assert_match "81.2.69.144", response.body
  end

  test "a member pane lists the rest of their cluster when nothing links them directly" do
    member!("UONE")
    cluster!("UONE", "UROOT", accounts: 3, active: true)
    cluster!("UROOT", "UROOT", accounts: 3, active: true)
    cluster!("UTHIRD", "UROOT", accounts: 3, active: false)

    get fd_member_links_path("UONE")
    assert_response :success

    assert_select ".link-mates-title", "Same cluster"
    assert_select ".link-mates-head", /2 other accounts, 1 deactivated/
    assert_select ".facepile a.facepile-face.is-gone[title*=deactivated]", 1
    assert_select ".link-mates-open", 1
    assert_match "UROOT", response.body
    assert_match "UTHIRD", response.body
    assert_select ".empty-title", count: 0
  end

  test "a big cluster shows a dozen of its accounts and one way into it" do
    member!("UONE")
    cluster!("UONE", "UBIG00", accounts: 21, active: true)
    20.times { |n| cluster!("UBIG#{n.to_s.rjust(2, '0')}", "UBIG00", accounts: 21, active: true) }

    get fd_member_links_path("UONE")
    assert_select ".facepile a.facepile-face", Fd::MemberLink::MATES_SHOWN
    assert_select ".facepile .facepile-more", "+4"
    assert_select ".link-mates-head", /20 other accounts/
    assert_select "a", text: "Open cluster", count: 1
  end

  private

  def gone!(user_id)
    as_pipeline("UPDATE fd.member SET is_deleted = true WHERE user_id = ?", user_id)
  end

  def verdict!(one, two, verdict)
    a, b = [one, two].sort
    as_pipeline("INSERT INTO fd.member_link_verdict (a_user_id, b_user_id, verdict, decided_by) " \
                "VALUES (?, ?, ?, 'UME')", a, b, verdict)
    seeded!("fd.member_link_verdict", "a_user_id", a)
  end

  def cluster!(user_id, cluster_id, accounts:, active:, ring: false, conflict: false)
    as_pipeline("INSERT INTO fd.member_cluster (user_id, cluster_id, accounts, ring, active, conflict) " \
                "VALUES (?, ?, ?, ?, ?, ?)", user_id, cluster_id, accounts, ring, active, conflict)
    seeded!("fd.member_cluster", "user_id", user_id)
  end

  def link!(one, two, score:, top:, signals: "{}")
    a, b = [one, two].sort
    as_pipeline(<<~SQL.squish, a, b, score, top, signals)
      INSERT INTO fd.member_link (a_user_id, b_user_id, score, top_signal, signals)
      VALUES (?, ?, ?, ?, ?::jsonb)
    SQL
    seeded!("fd.member_link", "a_user_id", a)
  end
end
