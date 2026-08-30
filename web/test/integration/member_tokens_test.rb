require "test_helper"

class MemberTokensTest < ActionDispatch::IntegrationTest
  setup do
    Fd::Flag.set!(:public_api, true, by: "UBOSS")
    @member = Staff.create!(user_id: "UMEMBER4")
    sign_in_as(@member)
  end

  teardown do
    Fd::Flag.delete_all
    Current.forget_flags
  end

  def mint(name: "Toolbox", lasting: "90")
    post you_tokens_path, params: { name: name, lasting: lasting }
  end

  test "the form does not go through turbo, so the answer is not thrown away" do
    get you_api_path(tab: "tokens")

    assert_select "form[action=?][data-turbo=false]", you_tokens_path, 1,
      "turbo drive discards a 200 from a form post, and the key would never be seen"
  end

  test "creating a key renders the one and only time it is shown" do
    assert_difference -> { Api::Token.count }, 1 do
      mint
    end

    assert_response :success
    assert_select ".modal-title", text: "Copy your key"
    assert_select ".secret code", 1
    assert_select ".warn-line"
  end

  test "the key on screen is the real one, and is not what we stored" do
    mint
    shown = css_select(".secret code").sole.text
    token = Api::Token.sole

    assert_equal Api::Token.digest_of(shown), token.digest
    assert_not_equal shown, token.digest
    assert shown.start_with?(Api::Token::LEAD)
  end

  test "the chosen expiry is the one written down" do
    mint(lasting: "30")

    assert_in_delta 30.days.from_now, Api::Token.sole.expires_at, 1.minute
  end

  test "no expiry is a real choice, not a default" do
    mint(lasting: "never")

    assert_nil Api::Token.sole.expires_at
  end

  test "a made up expiry falls back rather than storing nothing" do
    mint(lasting: "forever and ever")

    assert_in_delta 90.days.from_now, Api::Token.sole.expires_at, 1.minute
  end

  test "an unnamed key is refused" do
    assert_no_difference -> { Api::Token.count } do
      mint(name: "  ")
    end

    assert_redirected_to you_api_path(tab: "tokens")
  end

  test "minting is written to the audit log with its life" do
    mint(lasting: "30")

    said = Api::Event.where(verb: "token_minted").sole
    assert_equal @member.user_id, said.actor_user_id
    assert_equal "Toolbox, 30 days", said.detail
  end

  test "past the cap it is refused, and a revoked key frees a slot" do
    3.times { |i| mint(name: "key #{i}") }
    assert_equal 3, Api::Token.count

    mint(name: "one too many")
    assert_equal 3, Api::Token.count
    assert_match(/already hold 3/, flash[:alert])

    Api::Token.first.revoke!(by: @member.user_id)
    mint(name: "room now")

    assert_equal 4, Api::Token.count
  end

  test "an expired key does not hold a slot" do
    3.times { |i| mint(name: "key #{i}") }
    Api::Token.first.update!(expires_at: 1.day.ago)

    mint(name: "room now")

    assert_equal 4, Api::Token.count
  end

  test "nobody can mint while the public api is off" do
    Fd::Flag.set!(:public_api, false, by: "UBOSS")

    assert_no_difference -> { Api::Token.count } do
      mint
    end
  end

  test "signed out, nobody can mint at all" do
    delete logout_path

    assert_no_difference -> { Api::Token.count } do
      mint
    end

    assert_redirected_to login_path
  end
end
