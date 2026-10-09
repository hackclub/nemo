require "test_helper"

class FdLinkVerdictsTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  ACTIVE = "UVACTIVE".freeze
  GONE = "UVGONE".freeze

  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
    member!(ACTIVE)
    member!(GONE)
    as_pipeline("UPDATE fd.member SET is_deleted = true WHERE user_id = ?", GONE)
    a, b = [ACTIVE, GONE].sort
    as_pipeline("INSERT INTO fd.member_link (a_user_id, b_user_id, score, top_signal) VALUES (?, ?, 9.0, 'ip_stable')",
      a, b)
    seeded!("fd.member_link", "a_user_id", a)
    seeded!("fd.member_link_verdict", "a_user_id", a)
  end

  def judge(verdict, note: nil, back: fd_links_path)
    post fd_link_verdicts_path, params: { a: GONE, b: ACTIVE, verdict: verdict, note: note, back: back }
  end

  test "a pair is judged from needs review and leaves it" do
    get fd_links_path
    assert_select "button[data-verdict-a='#{ACTIVE}'][data-verdict-b='#{GONE}']", "Judge"
    assert_select ".modal-host[data-modal-id-value='link-verdict'] input[name='verdict']", 4

    assert_difference -> { Fd::LinkVerdict.count }, 1 do
      judge("different_people", note: "cousins")
    end
    assert_redirected_to fd_links_path
    assert_equal "verdict recorded", flash[:notice]
    follow_redirect!
    assert_select "button[data-verdict-a='#{ACTIVE}']", 0

    row = Fd::LinkVerdict.find_by!(a_user_id: [ACTIVE, GONE].min, b_user_id: [ACTIVE, GONE].max)
    assert_equal ["different_people", "UME", "cousins"], [row.verdict, row.decided_by, row.note]
  end

  test "a verdict is written to the audit log like the command writes it" do
    judge("same_person")

    entry = Fd::AuditEntry.where(entity_type: "member_link_verdict").order(:id).last
    assert_equal "linked", entry.verb
    assert_equal "UME", entry.actor_user_id
    assert_equal [ACTIVE, GONE].max, entry.subject_user_id
    assert_equal "same_person", entry.after["verdict"]
    assert_nil entry.before
  end

  test "a changed verdict keeps what it said before" do
    judge("same_person", note: "dm")
    judge("household")

    entry = Fd::AuditEntry.where(entity_type: "member_link_verdict").order(:id).last
    assert_equal "unlinked", entry.verb
    assert_equal "same_person", entry.before["verdict"]
    assert_equal "dm", Fd::LinkVerdict.last.note, "an empty note keeps the one already given"
    assert_match "verdict changed", flash[:notice]
  end

  test "saying the same thing twice writes nothing" do
    judge("staff_test")
    assert_no_difference -> { Fd::AuditEntry.where(entity_type: "member_link_verdict").count } do
      judge("staff_test")
    end
    assert_match "verdict unchanged", flash[:notice]
  end

  test "a judged pair shows its verdict and can be changed from all pairs" do
    judge("household")

    get fd_links_path(view: "pairs")
    assert_select ".state", "Household"
    assert_select "button[data-verdict-was='household']", "Change"
  end

  test "the member pane and the cluster page judge pairs too" do
    get fd_member_links_path(ACTIVE)
    assert_select "button[data-verdict-a='#{ACTIVE}'][data-verdict-b='#{GONE}']", "Judge"

    as_pipeline("INSERT INTO fd.member_cluster (user_id, cluster_id, accounts, active) VALUES (?, ?, 2, true), (?, ?, 2, false)",
      ACTIVE, GONE, GONE, GONE)
    seeded!("fd.member_cluster", "cluster_id", GONE)
    get fd_cluster_path(GONE)
    assert_select "h2", "Links"
    assert_select "button[data-modal-open='link-verdict']", minimum: 1
  end

  test "a judgement comes back to the page it was made on" do
    judge("same_person", back: fd_member_path(ACTIVE, do: "links"))
    assert_redirected_to fd_member_path(ACTIVE, do: "links")

    judge("household", back: "https://elsewhere.example/steal")
    assert_redirected_to fd_links_path
  end

  test "a verdict needs two accounts and one of the four answers" do
    post fd_link_verdicts_path, params: { a: ACTIVE, b: ACTIVE, verdict: "same_person" }
    assert_equal "pick two accounts", flash[:alert]

    post fd_link_verdicts_path, params: { a: ACTIVE, b: GONE, verdict: "maybe" }
    assert_equal "pick a verdict", flash[:alert]
  end

  test "somebody without link.verdict sees no buttons and is refused" do
    move_capability!("firefighter", "link.verdict", false, by: "UME")
    sign_in_as(hold_role!("UFF", "firefighter"))

    get fd_links_path
    assert_select "button[data-modal-open='link-verdict']", 0
    assert_select ".modal-host[data-modal-id-value='link-verdict']", 0

    assert_no_difference -> { Fd::LinkVerdict.count } do
      judge("same_person")
    end
  end
end
