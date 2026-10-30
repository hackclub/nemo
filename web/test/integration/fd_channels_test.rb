require "test_helper"

class FdChannelsTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    sign_in_as(@me)
    @channel = Analytics::DimChannel.where(archived: false).order(:channel_id).first
    skip "the corpus has no channel" if @channel.nil?
  end

  def guard!
    Fd::ChannelGuard.create!(kind: Fd::ChannelGuard::BOT_ALLOWLIST,
      channel_id: @channel.channel_id, opened_by: "UME")
  end

  test "channel show without guard returns success" do
    get fd_channel_path(@channel.channel_id)

    assert_response :success
  end

  test "channel show with guard and allow returns success" do
    guard!.allows.create!(subject_id: "B0CACHET", label: "Cachet", added_by: "UME")

    get fd_channel_path(@channel.channel_id)

    assert_response :success
  end

  def join_nemo!(inside)
    ActiveRecord::Base.connection.execute(
      "INSERT INTO fd.channel_membership (channel_id, inside) " \
      "VALUES (#{ActiveRecord::Base.connection.quote(@channel.channel_id)}, #{inside}) " \
      "ON CONFLICT (channel_id) DO UPDATE SET inside = EXCLUDED.inside"
    )
  end

  def record_join!(verb, why = nil, at: Time.current)
    connection = ActiveRecord::Base.connection
    connection.execute(
      "INSERT INTO fd.channel_joins (channel_id, verb, why, at) VALUES " \
      "(#{connection.quote(@channel.channel_id)}, #{connection.quote(verb)}, " \
      "#{connection.quote(why)}, #{connection.quote(at)})"
    )
  end

  test "channel show with nemo outside renders not a member warning" do
    join_nemo!(false)

    get fd_channel_path(@channel.channel_id)

    assert_select "p.sev-crit", "Nemo is not a member of this channel"
  end

  test "channel show with join refused for invite renders invite note" do
    join_nemo!(false)
    record_join!("refused", FdChannelsHelper::NEEDS_INVITE)

    get fd_channel_path(@channel.channel_id)

    assert_select "p.sev-crit", FdChannelsHelper::INVITE_NOTE
  end

  test "channel show with join then leave renders removed warning" do
    record_join!("joined", at: 1.hour.ago)
    record_join!("left")

    get fd_channel_path(@channel.channel_id)

    assert_select "p.sev-crit", "Nemo was removed from this channel"
  end

  test "channel_membership_label outside channel with refused join shows refused_note" do
    join_nemo!(false)
    record_join!("refused", "is_archived")

    get fd_channel_path(@channel.channel_id)

    assert_select "p.sev-crit", "Join failed: is_archived"
  end

  test "channel_membership_label without membership rows shows refused_note" do
    record_join!("refused", "is_archived")

    get fd_channel_path(@channel.channel_id)

    assert_select "p.sev-crit", "Join failed: is_archived"
  end

  test "channel show with nemo inside renders no warning" do
    join_nemo!(true)

    get fd_channel_path(@channel.channel_id)

    assert_select "p.sev-crit", count: 0
    assert_select "p.sev-warn", count: 0
  end

  test "channel show with unknown channel id returns success" do
    get fd_channel_path("C0NOTHING")

    assert_response :success
  end

  test "channels index signed out redirects to login" do
    reset!
    get fd_channels_path

    assert_redirected_to login_path
  end

  test "channel guard create stores opened_by and creates audit entry" do
    post fd_channel_guard_path(@channel.channel_id, "bot_allowlist")

    guard = Fd::ChannelGuard.live_for(@channel.channel_id)
    assert_not_nil guard
    assert_equal "UME", guard.opened_by
    assert Fd::AuditEntry.where(entity_type: "channel_guard", entity_id: guard.id,
      verb: "opened").exists?
  end

  test "channel guard create on guarded channel creates no row" do
    guard!

    assert_no_difference -> { Fd::ChannelGuard.count } do
      post fd_channel_guard_path(@channel.channel_id, "bot_allowlist")
    end
  end

  test "channel guard destroy sets state lifted and keeps allows" do
    guard = guard!
    guard.allows.create!(subject_id: "B0CACHET", added_by: "UME")

    delete fd_channel_guard_path(@channel.channel_id, "bot_allowlist")

    assert_nil Fd::ChannelGuard.live_for(@channel.channel_id)
    assert_equal "lifted", guard.reload.state
    assert_equal "UME", guard.lifted_by
    assert_not_nil guard.lifted_at
    assert_equal 1, guard.allows.count
  end

  test "channel guard destroy without guard creates no row" do
    delete fd_channel_guard_path(@channel.channel_id, "bot_allowlist")

    assert_equal 0, Fd::ChannelGuard.where(channel_id: @channel.channel_id).count
  end

  test "channel allows create stores added_by and creates audit entry" do
    guard = guard!

    post fd_channel_allows_path(@channel.channel_id, "bot_allowlist"),
      params: { subject_ids: ["B0CACHET"] }

    allow = guard.allows.find_by(subject_id: "B0CACHET")
    assert_not_nil allow
    assert_equal "UME", allow.added_by
    assert Fd::AuditEntry.where(entity_type: "channel_allow", entity_id: guard.id,
      verb: "added").exists?
  end

  test "channel allows create twice with same subject creates one row" do
    guard = guard!
    2.times do
      post fd_channel_allows_path(@channel.channel_id, "bot_allowlist"), params: { subject_ids: ["B0CACHET"] }
    end

    assert_equal 1, guard.allows.where(subject_id: "B0CACHET").count
  end

  test "channel allows create with invalid subject id creates no row" do
    guard = guard!

    post fd_channel_allows_path(@channel.channel_id, "bot_allowlist"), params: { subject_ids: ["not-an-id"] }

    assert_equal 0, guard.allows.count
  end

  test "channel allows create without guard creates no row" do
    post fd_channel_allows_path(@channel.channel_id, "bot_allowlist"), params: { subject_ids: ["B0CACHET"] }

    assert_equal 0, Fd::ChannelGuardAllow.count
  end

  test "channel allow destroy removes row and creates audit entry" do
    guard = guard!
    guard.allows.create!(subject_id: "B0CACHET", label: "Cachet", added_by: "UME")

    delete fd_channel_allow_path(@channel.channel_id, "bot_allowlist", "B0CACHET")

    assert_equal 0, guard.allows.count
    assert Fd::AuditEntry.where(entity_type: "channel_allow", entity_id: guard.id,
      verb: "removed").exists?
  end

  test "member finder with bots: true excludes non-bot members" do
    member = Fd::Member.live.where(is_bot: false).first
    skip "the corpus has no member" if member.nil?

    user_ids = Fd::MemberFinder.new(member.name).suggest(limit: Fd::Member::LIMIT, bots: true)
    assert_not_includes user_ids, member.user_id
  end

  test "channel guard destroy keeps guard events" do
    guard = guard!
    guard.events.create!(channel_id: @channel.channel_id, subject_id: "B0ZAPIER", verb: "kicked")

    delete fd_channel_guard_path(@channel.channel_id, "bot_allowlist")
    get fd_channel_path(@channel.channel_id)

    assert_response :success
    assert_equal 1, Fd::ChannelGuardEvent.where(channel_id: @channel.channel_id).count
  end

  test "channel guard create without channel.guard creates no guard" do
    firefighter = grant_role!("UFF9", "firefighter")
    override_capability!("firefighter", "channel.guard", false, by: "UME")
    sign_in_as(firefighter)

    post fd_channel_guard_path(@channel.channel_id, "bot_allowlist")

    assert_nil Fd::ChannelGuard.live_for(@channel.channel_id)
  end
end
