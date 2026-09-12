require "test_helper"

# Documents the intended access model for channels#index, confirmed against the
# live deployment: per-channel access gates the *detail page* only. A channel's
# existence, name, and aggregate volume/trend are workspace-transparent to anyone
# with basic channel analytics access, the same way the "Channels activity"
# distribution histograms above the treemap already are - there is no per-channel
# scoping on that data, by design, and there should not be.
class ChannelTreemapLeakTest < ActionDispatch::IntegrationTest
  setup do
    # "promethean" holds channel.read but not channel.all - an ordinary account
    # that must go through Channels::Audience's per-channel grant path for the
    # table and detail page, with no grants of its own.
    @ordinary = hold_role!("UORD1", "promethean")

    # DimChannel and MartChannelMomentum are dbt-owned (readonly? => true), so
    # .create! is blocked - insert_all bypasses AR callbacks/readonly and issues
    # a plain INSERT, which is fine for seeding a read-only mart in a test.
    Analytics::DimChannel.insert_all([
      { channel_id: "CUNGRANTED", name: "ungranted-channel", archived: false },
    ])

    now = Time.current
    Analytics::MartChannelMomentum.insert_all([
      {
        channel_id: "CUNGRANTED", name: "ungranted-channel", messages: 1000, prior_messages: 1000,
        prior_below_floor: false, pct_change: 0.0, share_of_total: 100.0, rank: 1,
        total_messages: 1000, active_channels: 1, prior_floor: 500,
        window_start: now - 27.days, window_end: now, prior_start: now - 55.days,
        prior_end: now - 28.days, metric_version: "v1",
      },
    ])
    # deliberately no Channels::Audience::Grant for this account or channel

    sign_in_as(@ordinary)
  end

  test "the treemap names and counts a channel even with no grant on it" do
    get channels_path

    assert_response :success
    assert_includes response.body, "ungranted-channel",
      "channel identity + aggregate volume is meant to be workspace-visible on channel.read alone"
  end

  test "the channel table stays scoped to what is actually granted" do
    get channels_path

    assert_match(/No channel is shared with you/, response.body)
  end

  test "the detail page is still the actual access boundary" do
    get channel_path("CUNGRANTED")

    assert_redirected_to channels_path(q: "CUNGRANTED")
    assert_match(/not shared with you/, flash[:alert].to_s)
  end
end
