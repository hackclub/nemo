require "test_helper"

class FdSessionsTest < ActionDispatch::IntegrationTest
  WHO = "USUB".freeze
  ALSO = "UALT".freeze

  setup do
    @me = hold_role!("UME", "community_manager")
  end

  def agent!(app, os)
    ApplicationRecord.connection.select_value(ApplicationRecord.sanitize_sql([<<~SQL.squish,
      INSERT INTO slack.user_agent (ua, app, os) VALUES (?, ?, ?)
      ON CONFLICT (md5(ua)) DO UPDATE SET app = EXCLUDED.app, os = EXCLUDED.os
      RETURNING id
    SQL
      "raw agent #{app} #{os}", app, os]))
  end

  def signed_in!(user_id, at:, ip: "81.2.69.144", ua_app: "Chrome 141",
    ua_os: "Windows 10 or 11", action: "user_login", source: "audit_logs",
    country: "GB", isp: "Sky", seen: 1)
    counted = %w[user_login user_login_failed anomaly].map { |one| action == one ? 1 : 0 }
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql([<<~SQL.squish, user_id,
      INSERT INTO fd.login_event AS held
        (user_id, source, hour, ip, ua_id, first_at, last_at, logins, failures, anomalies,
         country, isp, seen)
      VALUES (?, ?, date_trunc('hour', ?::timestamptz, 'UTC'), ?::inet, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (user_id, source, hour, ip, ua_id) DO UPDATE SET
        first_at = least(held.first_at, EXCLUDED.first_at),
        last_at = greatest(held.last_at, EXCLUDED.last_at),
        hits = held.hits + 1, logins = held.logins + EXCLUDED.logins,
        failures = held.failures + EXCLUDED.failures,
        anomalies = held.anomalies + EXCLUDED.anomalies, seen = held.seen + EXCLUDED.seen
    SQL
      source, at, ip, agent!(ua_app, ua_os), at, at, *counted, country, isp, seen]))
  end

  def crowd!(host, people)
    ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql([<<~SQL.squish, host, people]))
      INSERT INTO fd.member_trait (user_id, kind, value)
      SELECT 'UCROWD' || n, 'ip_prefix', ? FROM generate_series(1, ?) n
    SQL
  end

  test "sign-ins are grouped by the device they came from" do
    signed_in!(WHO, at: 2.days.ago)
    signed_in!(WHO, at: 1.day.ago, ua_app: "Slack Android 26", ua_os: "Android 14",
      ip: "27.109.113.219", country: "KH", isp: "Smart Axiata")

    sessions = Fd::MemberSessions.new(WHO)
    assert_equal 2, sessions.device_count
    assert_equal 2, sessions.address_count
    assert_includes sessions.devices.map(&:name), "Slack Android 26 · Android 14"
  end

  test "an address only theirs is told apart from one a couple of people share" do
    signed_in!(WHO, at: 1.hour.ago)

    address = Fd::MemberSessions.new(WHO).addresses.first
    assert address.alone?
    assert_not address.shared?
    assert_empty address.alongside
  end

  test "somebody else on a small range is named, because that is the whole point" do
    signed_in!(WHO, at: 1.hour.ago)
    signed_in!(ALSO, at: 2.hours.ago)

    address = Fd::MemberSessions.new(WHO).addresses.first
    assert address.shared?
    assert_equal [ALSO], address.alongside
  end

  test "a range a crowd shares names nobody, so a school cannot accuse a class" do
    signed_in!(WHO, at: 1.hour.ago)
    signed_in!(ALSO, at: 2.hours.ago)
    crowd!("81.2.69.0", 1_240)

    address = Fd::MemberSessions.new(WHO).addresses.first
    assert address.crowded?
    assert_empty address.alongside, "a crowded range must not name anybody"
  end

  test "a failed sign-in and an anomaly are counted, not hidden" do
    signed_in!(WHO, at: 3.hours.ago, action: "user_login_failed")
    signed_in!(WHO, at: 2.hours.ago, action: "anomaly")

    sessions = Fd::MemberSessions.new(WHO)
    assert_equal 1, sessions.failures
    assert_equal 1, sessions.anomalies
  end

  test "the geo and the network come from the access log, which the audit log lacks" do
    signed_in!(WHO, at: 1.hour.ago, source: "access_logs", country: "KH",
      isp: "Smart Axiata", seen: 9)

    address = Fd::MemberSessions.new(WHO).addresses.first
    assert_equal "KH", address.country
    assert_equal "Smart Axiata", address.isp
    assert_equal 9, address.seen
  end

  test "the drawer opens for a firefighter and needs no capability of its own" do
    signed_in!(WHO, at: 1.hour.ago)
    sign_in_as(hold_role!("UFF", "firefighter"))

    get fd_member_logins_path(WHO)
    assert_response :success
    assert_select ".sessions"
    assert_match "Chrome 141", response.body
  end

  test "the drawer answers inside the frame that asked, or turbo drops it" do
    signed_in!(WHO, at: 1.hour.ago)
    sign_in_as(@me)

    get fd_member_logins_path(WHO)
    assert_select %(turbo-frame#member-sessions-#{WHO}), 1,
      "the reply must carry the frame the modal is waiting on"
  end

  test "a member with nothing on file still answers inside the frame" do
    sign_in_as(@me)

    get fd_member_logins_path("UEMPTY")
    assert_select %(turbo-frame#member-sessions-UEMPTY), 1
  end

  test "reading somebody's addresses is written down against the reader" do
    signed_in!(WHO, at: 1.hour.ago)
    sign_in_as(@me)

    assert_difference -> { AccessLog.where(field_class: "login").count }, 1 do
      get fd_member_logins_path(WHO)
    end
    assert_equal WHO, AccessLog.where(field_class: "login").last.subject_user_id
  end

  test "somebody who may not read identity is refused the drawer" do
    Authz::Override.create!(role: "firefighter", capability: "identity.read",
      allowed: false, changed_by: "UME")
    sign_in_as(hold_role!("UOBS", "firefighter"))

    get fd_member_logins_path(WHO)
    assert_response :redirect
  end

  test "a member with nothing on file says so rather than looking empty" do
    sign_in_as(@me)

    get fd_member_logins_path("UNOBODY")
    assert_response :success
    assert_select ".empty-title", "Nothing on file"
  end

  test "the member page offers sessions and loads them only when opened" do
    sign_in_as(@me)

    assert_no_difference -> { AccessLog.where(field_class: "login").count } do
      get fd_member_path(WHO)
    end
    assert_select %([data-modal-open="member-sessions"])
    assert_select %(turbo-frame#member-sessions-#{WHO}[loading="lazy"])
  end
end
