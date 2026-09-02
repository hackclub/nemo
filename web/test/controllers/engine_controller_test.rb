require "test_helper"

class EngineControllerTest < ActionDispatch::IntegrationTest
  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hackclub] = nil
  end

  test "the three tabs each render, and an unknown tab falls back to runs" do
    sign_in_as(hold_role!("UTESTCM1", "community_manager"))

    get engine_path
    assert_response :success

    get engine_path(tab: "coverage")
    assert_select ".card-title", text: "Which days of data each source holds"

    get engine_path(tab: "teleporter")
    assert_select ".card-title", text: "Tonight", message: "an unknown tab falls back to runs"
  end

  test "the sources tab lists every source with what it declares" do
    sign_in_as(hold_role!("UTESTCM1", "community_manager"))

    get engine_path(tab: "sources")

    assert_response :success
    assert_select ".lrow", count: Engine::Source::KEYS.size
    assert_select ".lrow .skey b", text: "member_channels", count: 1,
      message: "a stage the old hardcoded list never knew about"
    assert_select ".lrow .skey b", text: "channel_membership", count: 1
  end

  test "a source can be triggered from the row that describes it" do
    sign_in_as(hold_role!("UTESTCM1", "community_manager"))

    assert_difference -> { SyncRequest.count }, 1 do
      post engine_stage_path(stage: "member_channels")
    end

    assert_equal "member_channels", SyncRequest.recent_first.first.stage
  end

  test "a community manager queues a full sync" do
    sign_in_as(hold_role!("UTESTCM1", "community_manager"))

    assert_difference -> { SyncRequest.count }, 1 do
      post engine_sync_path
    end

    assert_redirected_to engine_path
    request = SyncRequest.recent_first.first
    assert_equal "full", request.kind
    assert_equal "queued", request.status
    assert_equal "UTESTCM1", request.requested_by
    assert_nil request.stage
  end

  test "a second request is refused while one is already active" do
    sign_in_as(hold_role!("UTESTCM1", "community_manager"))
    post engine_sync_path

    assert_no_difference -> { SyncRequest.count } do
      post engine_sync_path
    end

    assert_equal "a sync is already queued or running", flash[:alert]
  end

  test "a finished request does not block a new one" do
    sign_in_as(hold_role!("UTESTCM1", "community_manager"))
    post engine_sync_path
    SyncRequest.recent_first.first.update!(status: "done")

    assert_difference -> { SyncRequest.count }, 1 do
      post engine_sync_path
    end
  end

  test "an unauthenticated visitor cannot queue a sync" do
    assert_no_difference -> { SyncRequest.count } do
      post engine_sync_path
    end

    assert_redirected_to login_path
  end

  def firefighter
    boss = hold_role!("UTESTCM9", "community_manager")
    Fd::AccessGrant.give!("UHAND9", role: "firefighter", by: boss.user_id, reason: "works here")
    Staff.find("UHAND9")
  end

  test "a firefighter cannot queue a full sync" do
    sign_in_as(firefighter)

    assert_no_difference -> { SyncRequest.count } do
      post engine_sync_path
    end

    assert_redirected_to root_path
    assert_match(/no community access/, flash[:alert])
  end

  test "a firefighter cannot trigger a stage" do
    sign_in_as(firefighter)

    assert_no_difference -> { SyncRequest.count } do
      post engine_stage_path(stage: "member_channels")
    end

    assert_redirected_to root_path
    assert_match(/no community access/, flash[:alert])
  end

  test "a firefighter cannot cancel a sync somebody else queued" do
    boss = hold_role!("UTESTCM8", "community_manager")
    queued = SyncRequest.queue!(kind: "full", requested_by: boss.user_id)
    sign_in_as(firefighter)

    post engine_cancel_path

    assert_redirected_to root_path
    assert_not_equal "cancelling", queued.reload.status,
      "a firefighter must not be able to stop a run"
  end
end
