require "test_helper"

class FdChatTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    @kase = make_case
    sign_in_as(@me)
  end

  test "a message to the team answers with a stream that reloads the log" do
    post fd_case_chats_path(@kase), params: { body: "who wants this one?" },
      as: :turbo_stream

    assert_response :success
    assert_match(/turbo-stream action="reload_frame"/, response.body)
    assert_match(/target="chat-log-#{@kase.id}"/, response.body)
    assert_no_match(/src=/, response.body, "each viewer reloads the thread they are on")
  end

  test "the stream carries the log's version, so a reload already done is skipped" do
    post fd_case_chats_path(@kase), params: { body: "who wants this one?" },
      as: :turbo_stream
    version = Fd::ChatVersion.for(@kase.id)

    assert_match(/version="#{Regexp.escape(version)}"/, response.body)

    get fd_case_chat_log_path(@kase)
    assert_select ".chat-log[data-version=?]", version
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

  test "the chat frame knows where to reload from without refetching on sight" do
    get fd_case_path(@kase, tab: "report")

    frame = css_select("turbo-frame#chat-log-#{@kase.id}").first
    assert frame, "the chat log has to be a frame for the broadcast to target"
    assert_nil frame["src"],
      "a src on a frame we already filled is refetched at once, whatever complete says"
    assert_equal fd_case_chat_log_path(@kase), frame["data-src"],
      "reload_frame and catch-up read this, or reload() fetches nothing"
  end

  test "a browser that lost the socket is told which frame to catch up" do
    get fd_case_path(@kase, tab: "report")

    chat = css_select("div.chat").first
    assert_includes chat["data-controller"].split, "catch-up"
    assert_equal "chat-log-#{@kase.id}", chat["data-catch-up-frame-value"]
    assert_equal chat["data-catch-up-frame-value"],
      css_select("turbo-frame#chat-log-#{@kase.id}").first["id"],
      "a reconnect that reloads nothing would leave the pane stale for good"
    assert css_select("div.chat turbo-cable-stream-source").any?,
      "the controller watches inside itself, so the source has to be in there"
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

  def with_a_reporter
    reporter = Fd::Member.first.user_id
    report = Fd::CaseReport.create!(case_id: @kase.id, reporter_user_id: reporter,
      is_anonymous: false, body: "look at this", source_app: "shroud", received_at: 2.days.ago)
    Fd::IntakeConversation.create!(report_id: report.id, member_user_id: reporter,
      channel_id: "D0REP", thread_ts: "1700.5", opened_at: 2.days.ago)
  end

  test "a marked message typed at the team endpoint goes to the reporter, signed" do
    with_a_reporter
    post fd_case_chats_path(@kase), params: { body: "?we are looking at it" },
      as: :turbo_stream

    assert_equal 0, Fd::CaseChat.where(case_id: @kase.id).count, "it left the room"
    queued = Fd::IntakeOutbox.sole
    assert_equal "we are looking at it", queued.body
    assert_equal "signed", queued.mode
    assert_equal "UME", queued.requested_by
  end

  test "the tilde takes your name off a reply typed at the team endpoint" do
    with_a_reporter
    post fd_case_chats_path(@kase), params: { body: "~?we are looking at it" },
      as: :turbo_stream

    assert_equal "body", Fd::IntakeOutbox.sole.mode
  end

  test "a tilde on its own is kept as words, not read as a mark" do
    post fd_case_chats_path(@kase), params: { body: "~hi team" }, as: :turbo_stream

    assert_equal "~hi team", Fd::CaseChat.where(case_id: @kase.id).sole.body
    assert_equal 0, Fd::IntakeOutbox.count
  end

  test "the reply endpoint signs by default and takes the anon flag" do
    with_a_reporter
    post fd_case_replies_path(@kase), params: { body: "we are on it" }, as: :turbo_stream
    assert_equal "signed", Fd::IntakeOutbox.sole.mode

    post fd_case_replies_path(@kase), params: { body: "and again", anon: "1" },
      as: :turbo_stream
    assert_equal "body", Fd::IntakeOutbox.order(:id).last.mode
  end

  test "somebody who may not reply cannot get there through the team endpoint" do
    with_a_reporter
    hand = Account.create!(user_id: "UHAND")
    hold_role!("UHAND", "firefighter")
    move_capability!("firefighter", "case.reply", false, by: @me.user_id)
    sign_in_as(hand)

    post fd_case_chats_path(@kase), params: { body: "?we are looking at it" }

    assert_equal 0, Fd::IntakeOutbox.count
    assert_equal 0, Fd::CaseChat.where(case_id: @kase.id).count, "and it is not filed as chat"
    assert_not_nil flash[:alert]
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

  test "a dead token is given up on, not tried again for every message" do
    in_the_firehouse
    dead = ->(**) { { "ok" => false, "error" => "token_revoked" } }

    said = instead_of(:post_message, dead) { say }

    assert_nil said.mirrored_as
    assert_nil Fd::StaffSlack.held_by("UME"), "it stops claiming messages it cannot send"
    row = Fd::StaffSlack.find_by(staff_user_id: "UME")
    assert row.given_up?
    assert_equal "token_revoked", row.last_error
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
