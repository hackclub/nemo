require "test_helper"

class FdAuditHistogramTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  setup do
    @me = hold_role!("UHISTME", "community_manager")
    sign_in_as(@me)
  end

  def slack!(at:, action: "user_login")
    id = SecureRandom.uuid
    as_pipeline(<<~SQL.squish, id, at, action, { id: id, action: action }.to_json)
      INSERT INTO slack.audit_event (id, at, action, actor_kind, actor_id, entity_kind, entity_id,
                                     ours, payload, source_key)
      VALUES (?::uuid, ?, ?, 'user', 'UHISTWHO', 'user', 'UHISTWHO', false, ?::jsonb, 'test')
    SQL
    seeded!("slack.audit_event", "id", id)
  end

  def bars
    node = css_select("[data-controller=chart]").first
    assert node, "no chart drawn"
    JSON.parse(node["data-chart-data-value"]).then do |data|
      data["labels"].zip(data["datasets"].first["data"])
    end
  end

  def chart = bars.to_h

  test "the page loads the histogram lazily above the rows" do
    slack!(at: 1.hour.ago)

    get fd_audit_path(q: "action:user_login")
    assert_select "turbo-frame#audit-histogram[loading=lazy][src=?]",
      fd_audit_histogram_path(q: "action:user_login")
  end

  test "an empty search draws no histogram" do
    get fd_audit_path(q: "action:nothing_like_this")
    assert_select "turbo-frame#audit-histogram", count: 0
  end

  test "it counts the last thirty days by default, a bar a day" do
    travel_to Time.utc(2026, 10, 10, 12) do
      sign_in_as(@me)
      slack!(at: Time.utc(2026, 10, 9, 10))
      slack!(at: Time.utc(2026, 10, 9, 11))
      slack!(at: Time.utc(2026, 10, 1, 10))
      slack!(at: Time.utc(2026, 8, 1, 10))

      get fd_audit_histogram_path
      assert_response :success
      counts = chart
      assert_equal 30, counts.size
      assert_equal "2026-09-11", counts.keys.first
      assert_equal "2026-10-10", counts.keys.last
      assert_equal 2, counts["2026-10-09"]
      assert_equal 1, counts["2026-10-01"]
      assert_equal 0, counts["2026-10-02"]
    end
  end

  test "it follows the search and its dates" do
    slack!(at: Time.utc(2026, 9, 2, 10))
    slack!(at: Time.utc(2026, 9, 3, 10))
    slack!(at: Time.utc(2026, 9, 3, 11), action: "user_logout")

    get fd_audit_histogram_path(q: "action:user_login after:2026-09-01 before:2026-09-05")
    assert_equal({ "2026-09-01" => 0, "2026-09-02" => 1, "2026-09-03" => 1, "2026-09-04" => 0 }, chart)
  end

  test "days are the viewer's days" do
    member!("UHISTME")
    as_pipeline("UPDATE fd.member SET tz = 'America/New_York' WHERE user_id = 'UHISTME'")
    slack!(at: Time.utc(2026, 9, 3, 2, 30))

    get fd_audit_histogram_path(q: "after:2026-09-02 before:2026-09-05")
    assert_equal({ "2026-09-02" => 1, "2026-09-03" => 0, "2026-09-04" => 0 }, chart)
  end

  test "the last 24 hours is a bar an hour over 24 hours, not two days" do
    travel_to Time.utc(2026, 10, 10, 12, 20) do
      sign_in_as(@me)
      slack!(at: Time.utc(2026, 10, 10, 11, 5))
      slack!(at: Time.utc(2026, 10, 9, 13, 0))
      slack!(at: Time.utc(2026, 10, 9, 12, 0))

      get fd_audit_path(q: "last:24h")
      assert_equal 2, css_select("td.audit-when").size

      get fd_audit_histogram_path(q: "last:24h")
      counts = bars
      assert_equal 25, counts.size
      assert_equal ["12:00", 0], counts.first
      assert_equal ["13:00", 1], counts[1]
      assert_equal ["11:00", 1], counts[23]
      assert_equal ["12:00", 0], counts.last

      keys = JSON.parse(css_select("[data-controller=chart]").first["data-chart-brush-keys-value"])
      assert_equal "2026-10-09T13:00", keys[1]
    end
  end

  test "the last seven days is seven bars, today included" do
    travel_to Time.utc(2026, 10, 10, 12) do
      sign_in_as(@me)
      get fd_audit_histogram_path(q: "last:7d")
      assert_equal (Date.new(2026, 10, 4)..Date.new(2026, 10, 10)).map(&:iso8601), chart.keys
    end
  end

  test "dragging across hours sets an hour range" do
    get fd_audit_path(q: "last:24h", start: "2026-10-09T13:00", end: "2026-10-09T15:00")
    assert_redirected_to fd_audit_path(q: "after:2026-10-09T13:00 before:2026-10-09T16:00")
    follow_redirect!
    assert_select ".audit-chips .chip-on", text: /after 2026-10-09 13:00/
  end

  test "dragging across it sets the range on the same search" do
    get fd_audit_histogram_path(q: "action:user_login", view: "everything")
    node = css_select("[data-controller=chart]").first
    assert_equal "true", node["data-chart-brush-value"]
    assert_equal fd_audit_path(q: "action:user_login", view: "everything"), node["data-chart-brush-href-value"]

    get fd_audit_path(q: "action:user_login", view: "everything", start: "2026-09-02", end: "2026-09-04")
    assert_redirected_to fd_audit_path(view: "everything",
      q: "action:user_login after:2026-09-02 before:2026-09-05")
  end

  test "slack events are left out without audit.read" do
    ff = hold_role!("UHISTFF", "firefighter")
    move_capability!("firefighter", "audit.read", false, by: "UHISTME")
    sign_in_as(ff)
    slack!(at: Time.utc(2026, 9, 2, 10))

    get fd_audit_histogram_path(q: "after:2026-09-01 before:2026-09-04")
    assert_equal({ "2026-09-01" => 0, "2026-09-02" => 0, "2026-09-03" => 0 }, chart)
  end
end
