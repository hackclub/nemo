require "test_helper"

class MemberTokensTest < ActionDispatch::IntegrationTest
  setup do
    Fd::Flag.set!(:public_api, true, by: "UBOSS")
    @member = Account.create!(user_id: "UMEMBER4")
    @client = make_app!(@member.user_id)
    sign_in_as(@member)
  end

  teardown do
    Fd::Flag.delete_all
    Current.forget_flags
  end

  def mint(name: "Toolbox", lifetime: "90")
    post settings_tokens_path, params: { app_id: @client.id, name: name, lifetime: lifetime }
  end

  test "keys page token form sets data-turbo=false" do
    get settings_keys_path

    assert_select "form[action=?][data-turbo=false]", settings_tokens_path, 1,
      "token form must set data-turbo=false"
  end

  test "token create renders the secret modal and creates one token" do
    assert_difference -> { Api::Token.count }, 1 do
      mint
    end

    assert_response :success
    assert_select ".modal-title", text: "Your key"
    assert_select ".secret code", 1
    assert_select ".warn-line"
  end

  test "token create stores the digest and not the secret" do
    mint
    secret = css_select(".secret code").sole.text
    token = Api::Token.sole

    assert_equal Api::Token.digest_of(secret), token.digest
    assert_not_equal secret, token.digest
    assert secret.start_with?(Api::Token::KEY_PREFIX)
  end

  test "token create with lifetime 30 sets expires_at 30 days out" do
    mint(lifetime: "30")

    assert_in_delta 30.days.from_now, Api::Token.sole.expires_at, 1.minute
  end

  test "token create with lifetime never stores nil expires_at" do
    mint(lifetime: "never")

    assert_nil Api::Token.sole.expires_at
  end

  test "token create with an unknown lifetime defaults to 90 days" do
    mint(lifetime: "forever and ever")

    assert_in_delta 90.days.from_now, Api::Token.sole.expires_at, 1.minute
  end

  test "token create with blank name creates no token and redirects" do
    assert_no_difference -> { Api::Token.count } do
      mint(name: "  ")
    end

    assert_redirected_to settings_keys_path
  end

  test "token create writes a token_minted event with the lifetime detail" do
    mint(lifetime: "30")

    event = Api::Event.where(verb: "token_minted").sole
    assert_equal @member.user_id, event.actor_user_id
    assert_equal "Toolbox, Toolbox, 30 days", event.detail
  end

  test "token create past tokens_per_owner is refused until a token is revoked" do
    cap = Api::Setting.value("tokens_per_owner")
    cap.times { |i| mint(name: "key #{i}") }
    assert_equal cap, Api::Token.count

    mint(name: "one too many")
    assert_equal cap, Api::Token.count
    assert_match(/Key limit reached \(#{cap}\)/, flash[:alert])

    Api::Token.first.revoke!(by: @member.user_id)
    mint(name: "room now")

    assert_equal cap + 1, Api::Token.count
  end

  test "expired token does not count toward tokens_per_owner" do
    cap = Api::Setting.value("tokens_per_owner")
    cap.times { |i| mint(name: "key #{i}") }
    Api::Token.first.update!(expires_at: 1.day.ago)

    mint(name: "room now")

    assert_equal cap + 1, Api::Token.count
  end

  test "token create with public_api flag off creates no token" do
    Fd::Flag.set!(:public_api, false, by: "UBOSS")

    assert_no_difference -> { Api::Token.count } do
      mint
    end
  end

  test "token create signed out redirects to login and creates no token" do
    delete logout_path

    assert_no_difference -> { Api::Token.count } do
      mint
    end

    assert_redirected_to login_path
  end
end
