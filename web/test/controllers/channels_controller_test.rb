require "test_helper"

class ChannelsControllerTest < ActionDispatch::IntegrationTest
  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hackclub] = nil
  end

  def busiest_channel
    id = Analytics::MartChannelDay.group(:channel_id)
      .order(Arel.sql("count(*) desc")).limit(1).pluck(:channel_id).first
    Analytics::DimChannel.find_by(channel_id: id, archived: false) ||
      Analytics::DimChannel.where(archived: false).first
  end

  def analyst
    staff = hold_role!("UTESTCHAN1", "analytics")
    sign_in_as(staff)
    staff
  end

  test "the default view is the overview" do
    analyst
    channel = busiest_channel

    get channel_path(channel.channel_id)

    assert_response :success
    assert_select "nav.views a.view[aria-current='true']", text: "Overview"
    assert_select "h2.card-title", text: "Traffic"
  end

  test "every tab renders its own cards and nothing from the others" do
    analyst
    channel = busiest_channel
    wanted = {
      "activity" => "Top posters",
      "newcomers" => "First posts",
      "messages" => "Texture",
      "neighbours" => "Neighbours"
    }

    wanted.each do |view, title|
      get channel_path(channel.channel_id, view: view)

      assert_response :success
      assert_select "h2.card-title", text: title
      assert_select "h2.card-title", text: "Traffic", count: 0
      assert_select "nav.views a.view[aria-current='true']", text: ChannelsController::VIEWS[view]
    end
  end

  test "an unknown view falls back to the overview" do
    analyst
    channel = busiest_channel

    get channel_path(channel.channel_id, view: "nonsense")

    assert_response :success
    assert_select "h2.card-title", text: "Traffic"
  end

  test "the range control only shows on the views a range applies to" do
    analyst
    channel = busiest_channel

    get channel_path(channel.channel_id)
    assert_select ".range-open", count: 1
    assert_select "#channel-range", count: 1

    get channel_path(channel.channel_id, view: "activity")
    assert_select ".range-open", count: 0
    assert_select "#channel-range", count: 0
  end

  test "the range preset is marked and carried across the tab links" do
    analyst
    channel = busiest_channel

    get channel_path(channel.channel_id, days: 7)

    assert_response :success
    assert_select ".range-open", text: /Last 7 days/
    assert_select "nav.views a[href*='days=7']"
  end

  test "a custom range swaps the presets for the two date fields" do
    analyst
    channel = busiest_channel
    edge = Channels::Pulse.edge

    get channel_path(channel.channel_id, start: (edge - 3).iso8601, end: edge.iso8601)

    assert_response :success
    assert_select ".range-dates input[name=?]", "start"
    assert_select ".range-dates input[name=?]", "end"
    assert_select ".range-open", text: /#{(edge - 3).strftime("%-d %b")}/
  end

  test "a range running past what the warehouse holds still renders" do
    analyst
    channel = busiest_channel
    edge = Channels::Pulse.edge

    get channel_path(channel.channel_id, start: edge.iso8601, end: (edge + 90).iso8601)

    assert_response :success
    assert_select "h2.card-title", text: "Traffic"
  end

  test "the activity view offers a month and honours the one asked for" do
    analyst
    channel = Analytics::DimChannel.find_by(
      channel_id: Analytics::MartChannelPerson.limit(1).pick(:channel_id)
    )
    months = Analytics::MartChannelPerson.where(channel_id: channel.channel_id)
      .distinct.order(month: :desc).pluck(:month)
    skip "one month only in this seed" unless months.many?

    get channel_path(channel.channel_id, view: "activity", month: months.second.iso8601)

    assert_response :success
    assert_select "h2.card-title", text: "Top posters"
    assert_select ".card-tools .btn", text: /#{months.second.strftime("%b %Y")}/
  end

  test "a channel with no warehouse rows still renders every tab" do
    analyst
    bare = Analytics::DimChannel.where(archived: false)
      .where.not(channel_id: Analytics::MartChannelDay.select(:channel_id)).first
    skip "every channel carries day rows in this seed" if bare.nil?

    ChannelsController::VIEWS.each_key do |view|
      get channel_path(bare.channel_id, view: view)

      assert_response :success
    end
  end

  test "a channel nobody shared sends you back to the list" do
    staff = Account.create!(user_id: "UTESTCHAN2")
    sign_in_as(staff)
    channel = busiest_channel

    get channel_path(channel.channel_id)

    assert_redirected_to channels_path(q: channel.channel_id)
  end

  test "an unknown channel says so rather than raising" do
    analyst

    get channel_path("CNOPE00000")

    assert_redirected_to channels_path(q: "CNOPE00000")
  end
end
