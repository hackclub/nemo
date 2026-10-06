require "test_helper"

class FdOverviewTest < ActionDispatch::IntegrationTest
  setup do
    @me = Account.create!(user_id: "UFF1")
    hold_role!("UFF1", "firefighter")
    sign_in_as(@me)

    AccessLog.create!(actor_id: "UOTHER", subject_user_id: "USUB",
      field_class: "identity", looked_at: 1.hour.ago)
  end

  test "the overview does not show what other people looked up" do
    get fd_root_path

    assert_response :success
  end
  def guard!(**over)
    Fd::MemberGuard.create!({
      kind: "shush", subject_id: "USUB", opened_by: "UMOD",
      reason: "being awful", expires_at: 7.days.from_now
    }.merge(over))
  end

  def panel
    response.body[/In force now.*?<\/section>/m]
  end

  def metric
    response.body[/In force<\/span>\s*<span class="metric-value">(\d+)/, 1]
  end

  test "with nothing held the tile says so and no panel is drawn" do
    get fd_root_path
    assert_equal "0", metric
    assert_match(/nothing is being held on anybody/, response.body)
    assert_nil panel
  end

  test "a guard on no case is counted and called out" do
    guard!
    get fd_root_path
    assert_equal "1", metric
    assert_match(/attached to no case/, response.body)
    assert_match(/no case/, panel)
  end

  test "once every guard has a case the tile stops nagging" do
    guard!(case_id: make_case.id)
    get fd_root_path
    assert_match(/all of it attached to a case/, response.body)
    assert_no_match(/attached to no case/, response.body)
  end

  test "a lifted guard is not in force" do
    guard!(state: "lifted", lifted_at: Time.current, lifted_by: "UMOD")
    get fd_root_path
    assert_equal "0", metric
    assert_nil panel
  end

  test "the panel says what nemo is actually doing about each one" do
    guard!
    guard!(kind: "channel_ban", channel_id: "C0266FRGV", subject_id: "UTWO", enforcement_status: "failed")
    guard!(subject_id: "UTHREE", enforced_by: "by_hand", enforcement_status: "held")
    get fd_root_path

    assert_equal "3", metric
    assert_match(/not yet/, panel)
    assert_match(/not holding/, panel)
    assert_match(/by hand/, panel)
  end

  test "the worst thing being held is listed first" do
    guard!(kind: "channel_ban", channel_id: "C0266FRGV", subject_id: "UBAN")
    guard!(subject_id: "USHUSH")
    get fd_root_path

    assert_operator panel.index("UBAN"), :<, panel.index("USHUSH")
  end

  test "a guard with no end date says so rather than showing nothing" do
    guard!(expires_at: nil)
    get fd_root_path
    assert_match(/no end date/, panel)
  end
end
