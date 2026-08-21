require "test_helper"

class FdYouTabTest < ActionDispatch::IntegrationTest
  setup do
    @boss = Staff.create!(user_id: "UBOSS", community_manager: true)
    @me = Staff.create!(user_id: "UME")
    Fd::AccessGrant.give!(@me.user_id, role: "firefighter", by: @boss.user_id, reason: "works here")
    ENV["NEMO_CLIENT_ID"] = "1.2"
    ENV["NEMO_CLIENT_SECRET"] = "shh"
  end

  teardown do
    ENV.delete("NEMO_CLIENT_ID")
    ENV.delete("NEMO_CLIENT_SECRET")
  end

  def link!(user_id = "UME", **attrs)
    row = Fd::StaffSlack.keep!(user_id, token: "xoxp-real", team_id: "T0FIRE",
      scopes: "chat:write")
    row.update!(attrs) if attrs.any?
    row
  end

  test "a firefighter reaches the you tab and sees nothing else on the page" do
    sign_in_as(@me)
    get fd_settings_path

    assert_response :success
    assert_select ".views .view", count: 1, text: /You/
    assert_select ".card-title", text: "Your Slack account"
    assert_select "table.data-table", count: 0
  end

  test "a firefighter asking for the access tab is refused, not shown it" do
    sign_in_as(@me)
    get fd_settings_path(tab: "access")

    assert_response :redirect
    assert_match(/community manager/, flash[:alert])
  end

  test "a manager still lands on access and keeps every tab" do
    sign_in_as(@boss)
    get fd_settings_path

    assert_select ".views .view", 5
    assert_select ".card-title", text: "Your Slack account", count: 0
  end

  test "a manager can open their own tab, and the counts stay on the strip" do
    sign_in_as(@boss)
    get fd_settings_path(tab: "you")

    assert_response :success
    assert_select ".card-title", text: "Your Slack account"
    assert_select ".views .view-count", text: Fd::Permission.keys.size.to_s
  end

  test "an unlinked account offers the link, and posts to start it" do
    sign_in_as(@me)
    get fd_settings_path(tab: "you")

    assert_select ".chip-off", text: "not linked"
    assert_select "form[action=?][method=post]", fd_slack_account_path
    assert_select "form[action=?] button[type=submit]", fd_slack_account_path, text: "Link Slack"
  end

  test "a linked account shows the scope and offers to unlink" do
    link!
    sign_in_as(@me)
    get fd_settings_path(tab: "you")

    assert_select ".chip-good", text: "linked"
    assert_select ".mono", text: "chat:write"
    assert_select "form[action=?] input[name=_method][value=delete]", fd_slack_account_path
    assert_select "button[type=submit]", text: "Link Slack", count: 0
  end

  test "a token slack stopped taking says so, and offers to link again" do
    link!(last_error: "token_revoked", last_error_at: Time.current)
    sign_in_as(@me)
    get fd_settings_path(tab: "you")

    assert_select ".chip-warn", text: "stopped working"
    assert_select ".strip b", text: /token_revoked/
    assert_select "button[type=submit]", text: "Link Slack again"
  end

  test "an unlinked account with nothing configured cannot be linked" do
    ENV.delete("NEMO_CLIENT_ID")
    sign_in_as(@me)
    get fd_settings_path(tab: "you")

    assert_select "form[action=?]", fd_slack_account_path, count: 0
    assert_select ".card-note", text: /not set up on this server/
  end

  test "somebody else's grant is not on your tab" do
    link!("UBOSS")
    sign_in_as(@me)
    get fd_settings_path(tab: "you")

    assert_select ".chip-off", text: "not linked"
  end

  test "an unlinked row that was given back reads as not linked" do
    link!.give_back!("UME")
    sign_in_as(@me)
    get fd_settings_path(tab: "you")

    assert_select ".chip-off", text: "not linked"
    assert_select "button[type=submit]", text: "Link Slack"
  end

  test "everybody gets the settings link in the rail" do
    sign_in_as(@me)
    get fd_cases_path

    assert_select ".rail a[href=?]", fd_settings_path
  end
end
