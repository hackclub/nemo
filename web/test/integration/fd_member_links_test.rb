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

  private

  def link!(one, two, score:, top:, signals: "{}")
    a, b = [one, two].sort
    as_pipeline(<<~SQL.squish, a, b, score, top, signals)
      INSERT INTO fd.member_link (a_user_id, b_user_id, score, top_signal, signals)
      VALUES (?, ?, ?, ?, ?::jsonb)
    SQL
    seeded!("fd.member_link", "a_user_id", a)
  end
end
