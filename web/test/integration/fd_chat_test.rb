require "test_helper"

class FdChatTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @kase = make_case
    sign_in_as(@me)
  end

  test "a message to the team answers with a stream that reloads the log" do
    post fd_case_chats_path(@kase), params: { body: "who wants this one?" },
      as: :turbo_stream

    assert_response :success
    assert_match(/turbo-stream action="reload_frame"/, response.body)
    assert_match(/target="chat-log-#{@kase.id}"/, response.body)
    assert_match(%r{src="/fd/cases/#{@kase.id}/chat_log"}, response.body)
  end

  test "the message is kept as working chat, not as a note" do
    post fd_case_chats_path(@kase), params: { body: "who wants this one?" },
      as: :turbo_stream

    said = Fd::CaseChat.where(case_id: @kase.id).sole
    assert_equal "who wants this one?", said.body
    assert_equal "UME", said.author_user_id
    assert_nil said.ts, "typed here, so it has not been to Slack yet"
    assert_equal 0, Fd::Note.where(case_id: @kase.id).count
  end

  test "a plain browser still gets a redirect" do
    post fd_case_chats_path(@kase), params: { body: "who wants this one?" }

    assert_redirected_to fd_case_path(@kase, tab: "report")
  end

  test "an empty message is refused" do
    post fd_case_chats_path(@kase), params: { body: "  " }

    assert_equal 0, Fd::CaseChat.where(case_id: @kase.id).count
    assert_match(/write something/, flash[:alert])
  end

  test "the chat log renders on its own for the frame to fetch" do
    Fd::CaseChat.create!(case_id: @kase.id, author_user_id: "UME", body: "on it",
      source_app: "fire_engine")
    get fd_case_chat_log_path(@kase)

    assert_response :success
    assert_select "turbo-frame#chat-log-#{@kase.id} .chat-log .said-body", text: "on it"
  end

  test "a reply with nobody to reply to says so" do
    post fd_case_replies_path(@kase), params: { body: "was this in DMs?" }

    assert_equal 0, Fd::IntakeOutbox.count
    assert_match(/nobody to reply to/, flash[:alert])
  end

  def instead_of(name, answer)
    original = Slack::Chat.method(name)
    Slack::Chat.define_singleton_method(name) do |*args, **kwargs|
      answer.respond_to?(:call) ? answer.call(*args, **kwargs) : answer
    end
    yield
  ensure
    Slack::Chat.define_singleton_method(name, original)
  end

  def in_the_firehouse
    ENV["FIREHOUSE_CHANNEL_ID"] = "C0FIRE"
    Fd::CaseReport.create!(case_id: @kase.id, is_anonymous: true, source_app: "shroud",
      received_at: 2.days.ago, forwarded_ts: "1700.0001")
    Fd::StaffSlack.keep!("UME", token: "xoxp-real", team_id: "T0FIRE", scopes: "chat:write")
  end

  def say(body = "did we warn them before?")
    post fd_case_chats_path(@kase), params: { body: body }, as: :turbo_stream
    Fd::CaseChat.where(case_id: @kase.id).last
  end

  test "with slack linked, the message goes out as you and the bot leaves it alone" do
    in_the_firehouse
    sent = nil
    answer = lambda do |**args|
      sent = args
      { "ok" => true, "ts" => "1700.0009" }
    end

    said = instead_of(:post_message, answer) { say }

    assert_equal "1700.0009", said.mirrored_ts
    assert_equal "user", said.mirrored_as
    assert_not_nil said.mirrored_at
    assert_equal "C0FIRE", sent[:channel]
    assert_equal "1700.0001", sent[:thread_ts], "it lands in the case thread, not the channel"
    assert_equal "xoxp-real", sent[:token]
    assert_equal "did we warn them before?", sent[:text]
    assert_not_nil Fd::StaffSlack.held_by("UME").last_used_at
  ensure
    ENV.delete("FIREHOUSE_CHANNEL_ID")
  end

  test "slack refusing it hands the message back to the bot and says why" do
    in_the_firehouse
    refusal = ->(**) { { "ok" => false, "error" => "not_in_channel" } }

    said = instead_of(:post_message, refusal) { say }

    assert_nil said.mirrored_ts, "nothing was sent, so nemo still has to carry it"
    assert_nil said.mirrored_as
    assert_equal "not_in_channel", Fd::StaffSlack.held_by("UME").last_error
  ensure
    ENV.delete("FIREHOUSE_CHANNEL_ID")
  end

  test "slack being unreachable hands the message back to the bot" do
    in_the_firehouse
    dead = ->(**) { raise Slack::Chat::Unavailable, "execution expired" }

    said = instead_of(:post_message, dead) { say }

    assert_nil said.mirrored_as
    assert_match(/execution expired/, Fd::StaffSlack.held_by("UME").last_error)
  ensure
    ENV.delete("FIREHOUSE_CHANNEL_ID")
  end

  test "without slack linked, the message is left for the bot untouched" do
    ENV["FIREHOUSE_CHANNEL_ID"] = "C0FIRE"
    Fd::CaseReport.create!(case_id: @kase.id, is_anonymous: true, source_app: "shroud",
      received_at: 2.days.ago, forwarded_ts: "1700.0001")

    said = instead_of(:post_message, ->(**) { flunk "nothing should be sent" }) { say }

    assert_nil said.mirrored_as
    assert_nil said.mirrored_ts
  ensure
    ENV.delete("FIREHOUSE_CHANNEL_ID")
  end

  test "a case with no card in the firehouse is left for the bot" do
    ENV["FIREHOUSE_CHANNEL_ID"] = "C0FIRE"
    Fd::StaffSlack.keep!("UME", token: "xoxp-real", team_id: "T0FIRE", scopes: "chat:write")

    said = instead_of(:post_message, ->(**) { flunk "there is no thread to post into" }) { say }

    assert_nil said.mirrored_as
  ensure
    ENV.delete("FIREHOUSE_CHANNEL_ID")
  end

  test "a mention survives, the rest is escaped for slack" do
    assert_equal "&lt;b&gt; <@U0A1> &amp; me",
      Fd::SlackPost.escape("<b> <@U0A1> & me")
  end
end
