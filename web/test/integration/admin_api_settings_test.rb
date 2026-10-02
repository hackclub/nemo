require "test_helper"

class AdminApiSettingsTest < ActionDispatch::IntegrationTest
  setup do
    @boss = hold_role!("UBOSS9", "community_manager")
    hold_role!("UFIRE9", "firefighter")
    @client = make_app!("UOWNER9")
    @token, = Api::Token.mint!(@client, "Toolbox")
    sign_in_as(@boss)
  end

  def dials
    Api::Setting::DEFAULTS.keys.index_with { |key| Api::Setting.value(key) }
  end

  test "the tab lists every token with its owner and its rate" do
    get admin_api_path

    assert_response :success
    assert_select ".data-table td", text: "Toolbox"
    assert_select ".data-table .tag", text: @token.shown
    assert_select ".setlist .setname", text: "Requests a minute, per key"
  end

  test "a manager moves a dial, and it is written down" do
    assert_difference -> { Api::Event.count }, 1 do
      patch admin_api_setting_path, params: { key: "rate_per_minute", value: 250 }
    end

    assert_equal 250, Api::Setting.value("rate_per_minute")
    said = Api::Event.last
    assert_equal ["setting_changed", @boss.user_id, "20 to 250"],
      [said.verb, said.actor_user_id, said.detail]
  end

  test "a dial that does not exist, or a silly number, changes nothing" do
    was = dials

    patch admin_api_setting_path, params: { key: "wingspan", value: 5 }
    assert_match(/not a setting/, flash[:alert])

    patch admin_api_setting_path, params: { key: "rate_per_minute", value: 0 }
    assert_match(/above nought/, flash[:alert])

    patch admin_api_setting_path, params: { key: "rate_per_minute", value: 999_999_999 }
    assert_match(/more than anybody needs/, flash[:alert])

    assert_equal was, dials
    assert_equal 0, Api::Event.count
  end

  test "a manager gives one token its own rate, and takes it away again" do
    patch admin_api_token_rate_path(@token), params: { value: 600 }
    assert_equal 600, @token.reload.rate

    patch admin_api_token_rate_path(@token), params: { value: "" }
    assert_nil @token.reload.rate_limit
    assert_equal Api::Setting.value("rate_per_minute"), @token.rate
    assert_equal 2, Api::Event.where(verb: "token_rate_set").count
  end

  test "a manager revokes somebody else's token, and it is named to them" do
    delete admin_api_token_path(@token)

    assert_predicate @token.reload, :revoked?
    assert_equal @boss.user_id, @token.revoked_by
    said = Api::Event.where(verb: "token_revoked").sole
    assert_match(/owned by UOWNER9/, said.detail)
  end

  test "revoking the same token twice is refused rather than logged twice" do
    delete admin_api_token_path(@token)

    assert_no_difference -> { Api::Event.count } do
      delete admin_api_token_path(@token)
    end

    assert_match(/no live token/, flash[:alert])
  end

  test "a firefighter cannot move a dial or touch a token" do
    sign_in_as(Account.find("UFIRE9"))

    patch admin_api_setting_path, params: { key: "rate_per_minute", value: 999 }
    delete admin_api_token_path(@token)

    assert_equal 20, Api::Setting.value("rate_per_minute")
    assert_not_predicate @token.reload, :revoked?
    assert_equal 0, Api::Event.count
  end

  test "a firefighter cannot reach the page at all" do
    sign_in_as(Account.find("UFIRE9"))
    get admin_api_path

    assert_redirected_to root_path
  end
end
