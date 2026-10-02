require "test_helper"

class FdResponsesTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "firefighter")
    sign_in_as(@me)
    @room = Analytics::DimChannel.where(archived: false).order(:channel_id).first
    skip "the corpus has no channel" if @room.nil?
  end

  def save(**over)
    post fd_configuration_autoresponse_path, params: {
      on: "1", emoji: "fd-reason, blunder", channel_id: @room.channel_id,
      cooldown_days: "7", body: "here is why we do not say"
    }.merge(over)
  end

  def shield(**over)
    post fd_configuration_unsub_shield_path,
      params: { on: "1", link: "https://unsub.hack.club" }.merge(over)
  end

  def said(key) = Fd::AppSetting.said(key)

  test "the responses tab opens" do
    get fd_configuration_path(tab: "responses")

    assert_response :success
    assert_match(/Autoresponse/, response.body)
    assert_match(/Unsubscribe shield/, response.body)
  end

  test "the watched channel is named" do
    named = Analytics::DimChannel.where.not(name: nil).first
    skip "the corpus has no named channel" if named.nil?
    save(channel_id: named.channel_id)
    get fd_configuration_path(tab: "responses")

    assert_match(/##{named.name}/, response.body)
    assert_no_match(/unnamed channel/, response.body)
  end

  test "the tab bar shows once there is more than one tab" do
    get fd_configuration_path

    assert_match(/Automod/, response.body)
    assert_match(/Responses/, response.body)
  end

  test "an autoresponse is saved and audited" do
    save

    assert Fd::AppSetting.on?(Fd::AppSetting::AUTORESPONSE_ON)
    assert_equal %w[fd-reason blunder], Fd::AppSetting.autoresponse_emoji
    assert_equal @room.channel_id, said(Fd::AppSetting::AUTORESPONSE_CHANNEL)
    assert_equal "here is why we do not say", said(Fd::AppSetting::AUTORESPONSE_BODY)
    assert_equal 7, Fd::AppSetting.autoresponse_cooldown_days
    assert_operator Fd::AuditEntry.where(entity_type: "app_setting", verb: "tuned").count,
      :>=, 1
  end

  test "emoji are taken with or without colons" do
    save(emoji: ":fd-reason:, blunder ,:blunder:")

    assert_equal %w[fd-reason blunder], Fd::AppSetting.autoresponse_emoji
  end

  test "turning it off keeps what was typed" do
    save
    save(on: "")

    assert_not Fd::AppSetting.on?(Fd::AppSetting::AUTORESPONSE_ON)
    assert_equal "here is why we do not say", said(Fd::AppSetting::AUTORESPONSE_BODY)
  end

  test "turning it on with no reply is refused" do
    save(body: "  ")

    assert_empty said(Fd::AppSetting::AUTORESPONSE_BODY)
    assert_match(/say what to answer with/, flash[:alert])
  end

  test "turning it on with no emoji is refused" do
    save(emoji: " , ")

    assert_match(/at least one emoji/, flash[:alert])
  end

  test "turning it on with no channel is refused" do
    save(channel_id: "")

    assert_match(/pick which channel/, flash[:alert])
  end

  test "a channel we have never heard of is refused" do
    save(channel_id: "C0NOTHING")

    assert_match(/is not a channel/, flash[:alert])
  end

  test "a cooldown outside the range is refused" do
    save(cooldown_days: "0")

    assert_match(/from 1 to/, flash[:alert])
  end

  test "turning it off does not check the rest" do
    save(on: "", body: "", emoji: "", channel_id: "")

    assert_not Fd::AppSetting.on?(Fd::AppSetting::AUTORESPONSE_ON)
    assert_nil flash[:alert]
  end

  test "the unsubscribe shield is saved" do
    shield

    assert Fd::AppSetting.on?(Fd::AppSetting::UNSUB_SHIELD_ON)
    assert_equal "https://unsub.hack.club", said(Fd::AppSetting::UNSUB_SHIELD_LINK)
  end

  test "a link that is not a link is refused" do
    shield(link: "unsub.hack.club")

    assert_empty said(Fd::AppSetting::UNSUB_SHIELD_LINK)
    assert_match(/not a link/, flash[:alert])
  end

  test "the shield is turned off on its own" do
    shield
    shield(on: "")

    assert_not Fd::AppSetting.on?(Fd::AppSetting::UNSUB_SHIELD_ON)
    assert_equal "https://unsub.hack.club", said(Fd::AppSetting::UNSUB_SHIELD_LINK)
  end

  test "somebody without the capability cannot save either" do
    drop_roles!("UME")
    hold_role!("UME", "gardener")
    save
    shield

    assert_empty said(Fd::AppSetting::AUTORESPONSE_BODY)
    assert_empty said(Fd::AppSetting::UNSUB_SHIELD_LINK)
  end
end
