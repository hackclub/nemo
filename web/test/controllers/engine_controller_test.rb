require "test_helper"

class EngineControllerTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hackclub] = nil
  end

  test "index renders every tab and an unknown tab with success" do
    sign_in_as(grant_role!("UTESTCM1", "community_manager"))

    get engine_path
    assert_response :success

    EngineController::TABS.each_key do |tab|
      get engine_path(tab: tab)
      assert_response :success, tab
    end

    get engine_path(tab: "teleporter")
    assert_response :success
  end

  def lane_run!(source, started_at, finished_at, status, parent: nil, step: nil)
    id = as_pipeline("INSERT INTO raw.ingest_run (source, source_key, status, started_at, finished_at, parent_run_id, step_index) " \
                     "VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING id", source, source, status, started_at, finished_at,
      parent, step).first["id"]
    seeded!("raw.ingest_run", "id", id)
    id
  end

  test "queues tab renders alt finder lanes with last live run and its steps" do
    sign_in_as(grant_role!("UTESTCM1", "community_manager"))
    as_pipeline("INSERT INTO fd.member_touch (user_id, touched_at) VALUES ('ULANEOLD', now() - interval '3 days')")
    seeded!("fd.member_touch", "user_id", "ULANEOLD")
    live = lane_run!("member_links_live", 30.seconds.ago, 27.seconds.ago, "ok")
    { "scope" => 1.3, "prepare" => 0.5, "gather" => 1.0, "settle" => 0.2 }.each_with_index do |(name, seconds), index|
      lane_run!("member_links_live:#{name}", 30.seconds.ago, 30.seconds.ago + seconds, "ok", parent: live, step: index + 1)
    end
    lane_run!("member_clusters", 20.seconds.ago, nil, "running")
    lane_run!("member_links", 10.seconds.ago, 5.seconds.ago, "failed")

    get engine_path(tab: "queues")
    assert_response :success

    assert_select ".link-lanes .card-title", "Alt finder lanes"
    assert_select ".link-lanes dl.facts-strip" do
      assert_select "dt", text: "Queued for rescoring"
      assert_select "dd", text: "3d ago"
      assert_select "dd", text: /just now\s+took 3s/
      assert_select "dd .lane-steps", text: "scope 1.3s, prepare 0.5s, gather 1.0s, settle 0.2s"
      assert_select "dd", text: /running\s+started just now/
      assert_select "dd", text: /just now\s+failed/
    end
  end

  test "storage tab lists today's table sizes and flags growth past twice the median" do
    sign_in_as(grant_role!("UTESTCM1", "community_manager"))
    as_pipeline(<<~SQL.squish)
      INSERT INTO ingest.table_size (day, table_name, bytes, rows, grew, median_growth, flagged)
      VALUES (current_date, 'slack.audit_event', 18253611008, 7765072, 943718400, 104857600, true),
             (current_date, 'fd.member', 52428800, 140000, 1048576, 1048576, false),
             (current_date - 1, 'fd.gone', 1, 1, NULL, NULL, false)
    SQL
    %w[slack.audit_event fd.member fd.gone].each { |name| seeded!("ingest.table_size", "table_name", name) }

    get engine_path(tab: "storage")
    assert_response :success

    assert_select "td", text: "slack.audit_event"
    assert_select "td", text: "fd.member"
    assert_select "td", text: "fd.gone", count: 0
    assert_select "td.warn", text: "+900 MB"
    assert_match "1 table past twice the 30-day median", response.body
  end

  test "storage tab without measurements renders Not measured yet" do
    sign_in_as(grant_role!("UTESTCM1", "community_manager"))
    as_pipeline("DELETE FROM ingest.table_size")

    get engine_path(tab: "storage")
    assert_response :success
    assert_match "Not measured yet", response.body
  end

  test "override breaker creates a muted breaker ack and redirects to faults" do
    sign_in_as(grant_role!("UTESTCM1", "community_manager"))

    assert_difference -> { Ingest::IncidentAck.count }, 1 do
      post engine_override_breaker_path(source_key: "team_stats")
    end

    row = Ingest::IncidentAck.find_by!(source_key: "team_stats", kind: "breaker")
    assert row.muted?
    assert_equal "UTESTCM1", row.acked_by
    assert_redirected_to engine_path(tab: "faults")
  end

  test "ack incident stores an unmuted ack and mute incident mutes the same row" do
    sign_in_as(grant_role!("UTESTCM1", "community_manager"))

    post engine_ack_incident_path(source_key: "member_days", kind: "source_failing")
    row = Ingest::IncidentAck.find_by!(source_key: "member_days", kind: "source_failing")
    assert_not row.muted?
    assert row.acked_at

    post engine_mute_incident_path(source_key: "member_days", kind: "source_failing")
    assert row.reload.muted?
    assert_equal 1, Ingest::IncidentAck.where(source_key: "member_days").count
  end

  test "override breaker without ops.engine creates no incident ack" do
    sign_in_as(grant_role!("UTESTCM2", "community_manager"))
    revoke_roles!("UTESTCM2")

    assert_no_difference -> { Ingest::IncidentAck.count } do
      post engine_override_breaker_path(source_key: "team_stats")
    end
  end

  test "stage post creates a SyncRequest with the stage" do
    sign_in_as(grant_role!("UTESTCM1", "community_manager"))

    assert_difference -> { SyncRequest.count }, 1 do
      post engine_stage_path(stage: "channel_membership")
    end

    assert_equal "channel_membership", SyncRequest.recent_first.first.stage
  end

  test "sync post creates a queued full SyncRequest for a community manager" do
    sign_in_as(grant_role!("UTESTCM1", "community_manager"))

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

  test "sync post with a queued SyncRequest creates no row and flashes alert" do
    sign_in_as(grant_role!("UTESTCM1", "community_manager"))
    post engine_sync_path

    assert_no_difference -> { SyncRequest.count } do
      post engine_sync_path
    end

    assert_equal "A sync is already queued or running", flash[:alert]
  end

  test "sync post with a cancelling SyncRequest creates no row" do
    sign_in_as(grant_role!("UTESTCM1", "community_manager"))
    post engine_sync_path
    SyncRequest.recent_first.first.update!(status: "cancelling")

    assert_no_difference -> { SyncRequest.count } do
      post engine_sync_path
    end

    assert_equal "A sync is already queued or running", flash[:alert]
  end

  test "sync post with a done SyncRequest creates a row" do
    sign_in_as(grant_role!("UTESTCM1", "community_manager"))
    post engine_sync_path
    SyncRequest.recent_first.first.update!(status: "done")

    assert_difference -> { SyncRequest.count }, 1 do
      post engine_sync_path
    end
  end

  test "sync post signed out redirects to login and creates no row" do
    assert_no_difference -> { SyncRequest.count } do
      post engine_sync_path
    end

    assert_redirected_to login_path
  end

  def firefighter
    manager = grant_role!("UTESTCM9", "community_manager")
    grant_role!("UHAND9", "firefighter")
    Account.find("UHAND9")
  end

  test "sync post as firefighter redirects to root and creates no row" do
    sign_in_as(firefighter)

    assert_no_difference -> { SyncRequest.count } do
      post engine_sync_path
    end

    assert_redirected_to root_path
    assert_match(/Community manager only/, flash[:alert])
  end

  test "stage post as firefighter redirects to root and creates no row" do
    sign_in_as(firefighter)

    assert_no_difference -> { SyncRequest.count } do
      post engine_stage_path(stage: "channel_membership")
    end

    assert_redirected_to root_path
    assert_match(/Community manager only/, flash[:alert])
  end

  test "cancel as firefighter redirects to root and keeps the status" do
    manager = grant_role!("UTESTCM8", "community_manager")
    queued = SyncRequest.queue!(kind: "full", requested_by: manager.user_id)
    sign_in_as(firefighter)

    post engine_cancel_path

    assert_redirected_to root_path
    assert_not_equal "cancelling", queued.reload.status,
      "a firefighter must not be able to stop a run"
  end
end
