require "test_helper"

class FdMemberViewsTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  setup do
    @me = grant_role!("UVIEWBOSS", "community_manager")
    sign_in_as(@me)
    %w[UVIEWLINKA UVIEWLINKB UVIEWWEAK UVIEWGONE UVIEWPLAIN].each { |user_id| member!(user_id) }
    as_pipeline("UPDATE fd.member SET is_deleted = true WHERE user_id = 'UVIEWGONE'")
    link!("UVIEWLINKA", "UVIEWLINKB", 9.0)
    link!("UVIEWPLAIN", "UVIEWWEAK", 3.5)
    Rails.cache.delete(Fd::MemberQuery.view_counts_key)
  end

  def link!(one, two, score)
    a, b = [one, two].sort
    as_pipeline("INSERT INTO fd.member_link (a_user_id, b_user_id, score, top_signal) VALUES (?, ?, ?, 'ip_stable')", a, b, score)
    seeded!("fd.member_link", "a_user_id", a)
  end

  def user_ids(view, term = nil)
    Fd::MemberQuery.new({ "view" => view, "q" => term }.compact, actor: @me).rows.map(&:user_id)
  end

  def tab_labels(selector)
    css_select(selector).map { |tab| tab.text.squish.sub(/\s*[\d,]+\z/, "") }
  end

  test "members table renders the five view tabs in order" do
    get fd_members_path(layout: "table")

    assert_equal ["All", "Linked", "Alt has actions", "In force", "Deactivated"], tab_labels("nav.views a.view")
  end

  test "members pane shows three tabs and puts the rest under More" do
    get fd_members_path

    assert_equal ["All", "Linked", "In force"], tab_labels("nav[aria-label='Member views'] > a.view")
    assert_equal ["Alt has actions", "Deactivated"], tab_labels(".views-more .menu-pop a")
  end

  test "members pane marks More as current when one of its views is open" do
    get fd_members_path(view: "alts")

    assert_select ".views-more summary[aria-current=true]", text: /More/
    assert_select ".views-more .menu-pop a[aria-current=true]", text: /Alt has actions/
  end

  test "linked view includes strongly linked members and excludes weakly linked ones" do
    linked = user_ids("linked")

    assert_includes linked, "UVIEWLINKA"
    assert_includes linked, "UVIEWLINKB"
    assert_not_includes linked, "UVIEWWEAK"
    assert_not_includes linked, "UVIEWPLAIN"
  end

  test "deactivated view lists deactivated members and counts_per_view reports them" do
    assert_includes user_ids("deactivated", "UVIEWGONE"), "UVIEWGONE"
    assert_not_includes user_ids("deactivated", "UVIEWPLAIN"), "UVIEWPLAIN"
    assert_not_includes Fd::MemberQuery.new({ "view" => "deactivated" }, actor: @me).rows.map(&:user_id), "UVIEWPLAIN"
    assert_operator Fd::MemberQuery.new({}).send(:counts_per_view).fetch("deactivated"), :>=, 1
  end

  def action_on!(user_id, reversed: false)
    kase = make_case(subject: user_id)
    Fd::Action.create!(case_id: kase.id, type_key: "warning", target_user_id: user_id, decided_by: "UMOD",
      performed_by: "UMOD", performed_at: 2.days.ago, source_app: "fire_engine",
      reversed_at: (1.day.ago if reversed), reversed_by: ("UMOD" if reversed))
  end

  def verdict!(one, two, verdict)
    a, b = [one, two].sort
    as_pipeline("INSERT INTO fd.member_link_verdict (a_user_id, b_user_id, verdict, decided_by) VALUES (?, ?, ?, 'UVIEWBOSS')",
      a, b, verdict)
    seeded!("fd.member_link_verdict", "a_user_id", a)
  end

  test "alt view lists members whose strongly linked account has an unreversed action" do
    action_on!("UVIEWLINKB")
    action_on!("UVIEWWEAK")

    alts = user_ids("alts")

    assert_includes alts, "UVIEWLINKA"
    assert_not_includes alts, "UVIEWLINKB"
    assert_not_includes alts, "UVIEWPLAIN"
  end

  test "alt view leaves out reversed actions and pairs marked different people" do
    %w[UVIEWALTX UVIEWALTY UVIEWALTZ].each { |user_id| member!(user_id) }
    link!("UVIEWALTX", "UVIEWALTY", 6.0)
    link!("UVIEWALTX", "UVIEWALTZ", 8.5)
    action_on!("UVIEWALTY", reversed: true)
    action_on!("UVIEWALTZ")
    verdict!("UVIEWALTX", "UVIEWALTZ", "different_people")

    assert_not_includes user_ids("alts"), "UVIEWALTX"
  end

  test "a same person verdict still counts for the alt view" do
    action_on!("UVIEWLINKB")
    verdict!("UVIEWLINKA", "UVIEWLINKB", "same_person")

    assert_includes user_ids("alts"), "UVIEWLINKA"
  end

  test "linked view and link counts leave out pairs marked different people" do
    verdict!("UVIEWLINKA", "UVIEWLINKB", "different_people")

    assert_not_includes user_ids("linked"), "UVIEWLINKA"
    assert_equal 0, Fd::MemberLink.link_counts_for("UVIEWLINKA").count
  end

  test "alt view rows name the alts that have actions" do
    action_on!("UVIEWLINKB")

    get fd_members_path(view: "alts", layout: "table", q: "UVIEWLINKA")

    assert_select "td", text: /alt: uviewlinkb/i
    assert_equal({ "UVIEWLINKA" => ["UVIEWLINKB"] }, Fd::MemberLink.actioned_alts_for(["UVIEWLINKA"]))
  end

  test "alt view empty state is a bare title" do
    assert_equal "No alts with actions", Fd::MemberQuery.new({ "view" => "alts" }).empty_note
  end
end
