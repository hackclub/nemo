require "test_helper"

class FdActionStandingTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    sign_in_as(@me)
    @kase = make_case(opened_at: 3.days.ago)
  end

  def guard!(**over)
    Fd::MemberGuard.create!({
      kind: "shush", subject_id: "USUB", opened_by: "UMOD",
      reason: "being awful", expires_at: 7.days.from_now
    }.merge(over))
  end

  def get_standing(**params)
    get fd_case_standing_path(@kase), params: { target_user_id: "USUB" }.merge(params)
  end

  def offered_guard_ids
    response.body.scan(/name="standing_guard_id" value="(\d*)"/).flatten
  end

  def a_named_channel
    Analytics::DimChannel.where.not(name: nil).first
  end

  test "standing shows the channel name for a channel scoped guard" do
    channel = a_named_channel
    guard!(kind: "channel_ban", channel_id: channel.channel_id)
    get_standing

    assert_match(/##{channel.name}/, response.body)
    assert_no_match(/unnamed channel/, response.body)
  end

  test "action modal shows the channel name for a channel scoped guard" do
    channel = a_named_channel
    guard!(kind: "channel_ban", channel_id: channel.channel_id, case_id: @kase.id)
    get fd_case_path(@kase, do: "action")

    assert_match(/##{channel.name}/, response.body)
    assert_no_match(/unnamed channel/, response.body)
  end

  test "standing offers guard on this case as disabled with already on this case note" do
    guard = guard!(case_id: @kase.id)
    get_standing

    assert_select %(input[name="standing_guard_id"][value="#{guard.id}"][disabled])
    assert_match(/already on this case/, response.body)
  end

  test "standing disables guard of another case after an action logs it on this case" do
    other = make_case
    guard = guard!(case_id: other.id)
    post fd_case_actions_path(@kase),
      params: { standing_guard_id: guard.id, target_user_id: "USUB" }
    get_standing

    assert_select %(input[name="standing_guard_id"][value="#{guard.id}"][disabled])
    assert_match(/already logged on this case/, response.body)
  end

  test "standing leaves guard of another case enabled" do
    other = make_case
    guard = guard!(case_id: other.id)
    get_standing

    assert_select %(input[name="standing_guard_id"][value="#{guard.id}"][disabled]), false
  end

  test "standing without target_user_id offers no guards" do
    guard!
    get_standing(target_user_id: "")
    assert_response :success
    assert_empty offered_guard_ids
  end

  test "standing for member without guards offers no guards" do
    get_standing
    assert_response :success
    assert_empty offered_guard_ids
  end

  test "standing offers guards of every kind and the new action option" do
    one = guard!
    two = guard!(kind: "channel_ban", channel_id: "C0266FRGV")
    get_standing

    assert_equal [one.id.to_s, two.id.to_s, ""], offered_guard_ids
    assert_match(/New action/, response.body)
  end

  test "standing omits guard in state lifted" do
    guard!(state: "lifted", lifted_at: Time.current, lifted_by: "UMOD")
    get_standing
    assert_empty offered_guard_ids
  end

  test "standing offers guard in state lifting" do
    lifting_guard = guard!(state: "lifting", lifted_by: "UMOD")
    get_standing
    assert_includes offered_guard_ids, lifting_guard.id.to_s
  end

  test "standing shows on no case or on case id for each guard" do
    guard!
    get_standing
    assert_match(/on no case/, response.body)

    other = make_case
    Fd::MemberGuard.update_all(case_id: other.id)
    get_standing
    assert_match(/on case #{other.id}/, response.body)
  end

  test "standing shows on this case for guard of the current case" do
    guard!(case_id: @kase.id)
    get_standing
    assert_match(/on this case/, response.body)
  end

  test "standing note shows case and expiry and omits nemo for failed enforcement" do
    guard!(enforcement_status: "failed", expires_at: Time.utc(2026, 3, 10))
    get_standing

    assert_match(/on no case/, response.body)
    assert_match(/until 10 Mar/, response.body)
    assert_no_match(/nemo/, response.body)
  end

  test "standing shows no end date for guard without expires_at" do
    guard!(expires_at: nil)
    get_standing
    assert_match(/no end date/, response.body)
  end

  test "standing offers channel_ban guard without kind param" do
    guard!(kind: "channel_ban", channel_id: "C0266FRGV")
    get_standing
    assert_equal 1, offered_guard_ids.count { |one| one.present? },
      "channel_ban guard not offered without kind param"
  end

  test "standing signed out redirects to login and offers no guards" do
    guard!
    delete logout_path
    get_standing
    assert_redirected_to root_path
    assert_empty offered_guard_ids
  end
  test "action modal orders member field then standing frame then fields" do
    guard!
    get fd_case_path(@kase, do: "action")
    body = response.body

    assert_operator body.index('data-combobox-name-value="target_user_id"'), :<,
      body.index('id="action-standing"')
    assert_operator body.index('id="action-standing"'), :<,
      body.index('data-action-standing-target="fields"')
  end

  test "action modal wires toggleFields and reloadStanding actions" do
    get fd_case_path(@kase, do: "action")
    body = response.body

    assert_match(/data-action-standing-target="fields"/, body)
    assert_match(/action-standing#toggleFields/, body) if Fd::MemberGuard.any?
    assert_match(/combobox:selected->action-standing#reloadStanding/, body)
    assert_match(/turbo:frame-load->action-standing#toggleFields/, body)
  end

  test "action modal for case with subject renders standing guards" do
    kase = make_case(subject: "USUB")
    guard!
    get fd_case_path(kase, do: "action")

    assert_match(/New action/, response.body)
    assert_match(/name="standing_guard_id"/, response.body)
  end

  test "action modal for case without subject renders no standing_guard_id input" do
    bare = make_case(subject: nil)
    guard!
    get fd_case_path(bare, do: "action")
    assert_no_match(/name="standing_guard_id"/, response.body)
  end
  test "action modal kind options set data-expires data-channel and data-lock" do
    get fd_case_path(@kase, do: "action")
    body = response.body

    assert_match(/data-expires="false" data-channel="false" data-lock="false" data-deactivates="false" value="warning"/,
      body)
    assert_match(/data-expires="true" data-channel="false" data-lock="false" data-deactivates="false" value="shush"/, body)
    assert_match(/data-expires="true" data-channel="true" data-lock="false" data-deactivates="false" value="channel_ban"/,
      body)
    assert_match(
      /data-expires="false" data-channel="false" data-lock="true" data-deactivates="false" value="locked_thread"/, body
    )
  end

  test "action modal hides expiry and channel fields and wires toggleKindFields" do
    get fd_case_path(@kase, do: "action")
    body = response.body

    assert_match(/data-action-standing-target="expiry" hidden/, body)
    assert_match(/data-action-standing-target="channel" hidden/, body)
    assert_match(/action-standing#toggleKindFields/, body)
  end
  test "action modal channel field uses channel combobox and no channel id placeholder" do
    get fd_case_path(@kase, do: "action")
    body = response.body

    assert_match(/data-combobox-kind-value="channel"/, body)
    assert_match(/data-combobox-name-value="channel_id"/, body)
    assert_no_match(/placeholder="C0266FRGV"/, body)
  end

  test "standing renders opt-dot opt-label and opt-note elements" do
    guard!
    get_standing

    assert_match(/class="opt-dot"/, response.body)
    assert_match(/class="opt-label"/, response.body)
    assert_match(/class="opt-note"/, response.body)
  end
end
