require "test_helper"

class EngineControllerTest < ActionDispatch::IntegrationTest
  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hackclub] = nil
  end

  test "the three tabs each render, and an unknown tab falls back to runs" do
    sign_in_as(Staff.create!(user_id: "UTESTCM1", community_manager: true))

    get engine_path
    assert_response :success

    get engine_path(tab: "coverage")
    assert_select ".card-title", text: "Day coverage"

    get engine_path(tab: "teleporter")
    assert_select ".card-title", text: "Latest run", message: "an unknown tab falls back to runs"
  end

  test "the sources tab lists every source with what it declares" do
    sign_in_as(Staff.create!(user_id: "UTESTCM1", community_manager: true))

    get engine_path(tab: "sources")

    assert_response :success
    assert_select "tbody tr", count: Engine::Source::KEYS.size
    assert_select "tbody td b", text: "member_channels", count: 1,
      message: "a stage the old hardcoded list never knew about"
    assert_select "tbody td b", text: "channel_membership", count: 1
  end

  test "a source can be triggered from the row that describes it" do
    sign_in_as(Staff.create!(user_id: "UTESTCM1", community_manager: true))

    assert_difference -> { SyncRequest.count }, 1 do
      post engine_trigger_stage_path(stage: "member_channels")
    end

    assert_equal "member_channels", SyncRequest.recent_first.first.stage
  end

  test "a community manager queues a full sync" do
    sign_in_as(Staff.create!(user_id: "UTESTCM1", community_manager: true))

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
    sign_in_as(Staff.create!(user_id: "UTESTCM1", community_manager: true))
    post engine_sync_path

    assert_no_difference -> { SyncRequest.count } do
      post engine_sync_path
    end

    assert_equal "a sync is already queued or running", flash[:alert]
  end

  test "a finished request does not block a new one" do
    sign_in_as(Staff.create!(user_id: "UTESTCM1", community_manager: true))
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
end
