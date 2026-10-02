require "test_helper"

class FdTranscriptsTest < ActionDispatch::IntegrationTest
  setup do
    @kept = Fd::ThreadTranscript.create!(
      channel_id: "C0BAHBV008Z", thread_ts: "1788927328.716919",
      body: "[2026-09-22T16:11:22.170Z] <USLACKBOT|Slackbot> This message was deleted.\n"
    )
    @key = "C0BAHBV008Z_1788927328.716919"
  end

  test "a signed out visitor gets nothing" do
    get destroy_transcript_path(key: @key)
    assert_response :redirect
    assert_not_equal @kept.body, response.body
  end

  test "someone with no conduct role gets nothing" do
    sign_in_as(hold_role!("UNOBODY", "gardener"))
    get destroy_transcript_path(key: @key)
    assert_response :redirect
    assert_not_equal @kept.body, response.body
  end

  test "a firefighter reads it" do
    sign_in_as(hold_role!("UFIRE", "firefighter"))
    get destroy_transcript_path(key: @key)

    assert_response :success
    assert_equal @kept.body, response.body
    assert_match "text/plain", response.media_type.to_s + response.headers["Content-Type"].to_s
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "private, no-store", response.headers["Cache-Control"]
  end

  test "a community manager reads it" do
    sign_in_as(hold_role!("UBOSS", "community_manager"))
    get destroy_transcript_path(key: @key)
    assert_response :success
  end

  test "reading one is audited" do
    sign_in_as(hold_role!("UFIRE2", "firefighter"))
    assert_difference -> { Fd::AuditEntry.where(verb: "read").count }, 1 do
      get destroy_transcript_path(key: @key)
    end
  end

  test "a malformed key is not found" do
    sign_in_as(hold_role!("UFIRE3", "firefighter"))
    ["../../etc/passwd", "C0BAHBV008Z", "notachannel_1.2", "C0BAHBV008Z_abc"].each do |bad|
      get "/cdn/destroy/#{bad}"
      assert_includes [404, 301, 302], response.status, bad
      assert_not_equal @kept.body, response.body, bad
    end
  end

  test "a thread nobody destroyed is not found" do
    sign_in_as(hold_role!("UFIRE4", "firefighter"))
    get destroy_transcript_path(key: "C0BAHBV008Z_1700000000.000001")
    assert_response :not_found
  end
end
