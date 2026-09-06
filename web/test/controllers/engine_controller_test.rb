require "test_helper"

class EngineControllerTest < ActionDispatch::IntegrationTest
  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hackclub] = nil
  end

  test "every tab renders, and an unknown tab falls back to runs" do
    sign_in_as(hold_role!("UTESTCM1", "community_manager"))

    get engine_path
    assert_response :success

    EngineController::TABS.each_key do |tab|
      get engine_path(tab: tab)
      assert_response :success, tab
    end

    get engine_path(tab: "teleporter")
    assert_response :success
  end

  test "a breaker override writes a one-night ack the pipeline honours" do
    sign_in_as(hold_role!("UTESTCM1", "community_manager"))

    assert_difference -> { Ingest::IncidentAck.count }, 1 do
      post engine_override_breaker_path(source_key: "team_stats")
    end

    row = Ingest::IncidentAck.find_by!(source_key: "team_stats", kind: "breaker")
    assert row.muted?
    assert_equal "UTESTCM1", row.acked_by
    assert_redirected_to engine_path(tab: "faults")
  end

  test "an incident can be acknowledged without muting it, and muted for a day" do
    sign_in_as(hold_role!("UTESTCM1", "community_manager"))

    post engine_ack_incident_path(source_key: "member_days", kind: "source_failing")
    row = Ingest::IncidentAck.find_by!(source_key: "member_days", kind: "source_failing")
    assert_not row.muted?
    assert row.acked_at

    post engine_mute_incident_path(source_key: "member_days", kind: "source_failing")
    assert row.reload.muted?
    assert_equal 1, Ingest::IncidentAck.where(source_key: "member_days").count
  end

  test "a visitor without ops.engine cannot touch incidents" do
    sign_in_as(hold_role!("UTESTCM2", "community_manager"))
    drop_roles!("UTESTCM2")

    assert_no_difference -> { Ingest::IncidentAck.count } do
      post engine_override_breaker_path(source_key: "team_stats")
    end
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

  test "a cancelling request still blocks a new one" do
    sign_in_as(hold_role!("UTESTCM1", "community_manager"))
    post engine_sync_path
    SyncRequest.recent_first.first.update!(status: "cancelling")

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
    hold_role!("UHAND9", "firefighter")
    Account.find("UHAND9")
  end

  test "a firefighter cannot queue a full sync" do
    sign_in_as(firefighter)

    assert_no_difference -> { SyncRequest.count } do
      post engine_sync_path
    end

    assert_redirected_to root_path
    assert_match(/Community manager only/, flash[:alert])
  end

  test "a firefighter cannot trigger a stage" do
    sign_in_as(firefighter)

    assert_no_difference -> { SyncRequest.count } do
      post engine_stage_path(stage: "member_channels")
    end

    assert_redirected_to root_path
    assert_match(/Community manager only/, flash[:alert])
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
