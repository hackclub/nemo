require "test_helper"

class ChannelsRangeTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  test "the default range renders" do
    get channels_path
    assert_response :success
  end

  test "each offered range renders and keeps its own condition and sort" do
    Channels::Window::PRESETS.each do |days|
      get channels_path(days: days, sort: "messages", direction: "desc",
        match: "all", c: { "0" => { "f" => "messages", "op" => "gt", "v" => ["1"] } })
      assert_response :success, "days=#{days} must render"
    end
  end

  test "a range nobody offered does not reach the query" do
    get channels_path(days: "45; drop table raw.message")
    assert_response :success
    assert_includes Channels::Window::PRESETS + [@controller.view_assigns["window"].pulled_days],
      @controller.view_assigns["window"].days
  end
end
