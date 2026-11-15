require "test_helper"

class FdActionGroupsTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    @kase = make_case
    sign_in_as(@me)
  end

  def log(**params)
    post fd_case_actions_path(@kase), params: {
      type_key: "warning", target_user_id: "USUB", reason: "kept at it after being asked to stop"
    }.merge(params)
  end

  def logged = @kase.actions.order(:id).to_a

  test "logging with additional actions stores one grouped action per type" do
    log(also: %w[dm deleted_messages])

    main, *others = logged
    assert_equal %w[warning dm deleted_messages], logged.map(&:type_key)
    assert_equal [main.id] * 3, logged.map(&:group_id)
    others.each do |action|
      assert_equal ["USUB", "kept at it after being asked to stop", main.category_key, main.performed_at],
        [action.target_user_id, action.reason, action.category_key, action.performed_at]
    end
    assert_equal "Warning, DM, Deleted messages logged on case #{@kase.id}", flash[:notice]
    assert_equal 3, Fd::AuditEntry.where(entity_type: "action", verb: "performed", entity_id: logged.map(&:id)).count
  end

  test "an enforcing action keeps its end and guard and the additional types get neither" do
    log(type_key: "shush", duration: "2d", also: %w[dm])

    shush, dm = logged
    assert_not_nil shush.expires_at
    assert_not_nil shush.guard_id
    assert_nil dm.expires_at
    assert_nil dm.guard_id
    assert_equal({}, dm.details)
    assert_equal shush.id, dm.group_id
  end

  test "the echo line names every type once" do
    log(type_key: "temp_ban", duration: "7d", also: %w[dm])

    echo = Fd::CaseChat.where(case_id: @kase.id).sole
    assert_match(/\ATemporary ban, DM logged on <@USUB>: kept at it/, echo.body)
  end

  test "additional actions ignore the chosen type and types that are not additional" do
    log(also: %w[warning shush temp_ban dm])

    assert_equal %w[warning dm], logged.map(&:type_key)
  end

  test "a single type stays ungrouped" do
    log

    assert_nil logged.sole.group_id
  end

  test "editing one type edits every type logged with it" do
    log(also: %w[dm])
    warning, dm = logged

    patch fd_case_action_path(@kase, dm), params: { reason: "spam in #lounge", category_key: "advertising" }

    assert_equal [["spam in #lounge", "advertising"]] * 2,
      [warning.reload, dm.reload].map { |action| [action.reason, action.category_key] }
    assert_equal 2, Fd::AuditEntry.where(entity_type: "action", verb: "edited",
      entity_id: [warning.id, dm.id]).count
  end

  test "reversing one type leaves the others live" do
    log(also: %w[dm])
    warning, dm = logged

    post fd_case_reversals_path(@kase), params: { action_id: warning.id, reversal_reason: "logged by mistake" }

    assert warning.reload.reversed?
    assert_not dm.reload.reversed?
  end

  test "action form offers the additional actions" do
    get fd_case_path(@kase, tab: "actions", do: "action")

    assert_select "[data-action-standing-target=also]" do
      assert_select "span", text: "Additional actions"
      assert_equal %w[warning dm deleted_messages],
        css_select("input[type=checkbox][name='also[]']").map { |input| input["value"] }
    end
  end
end
