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
  end

  test "the chat log renders as html, not only as a stream" do
    get fd_case_chat_log_path(@kase, thread: @kase.reports.first&.id)

    assert_response :success
  end

  test "the scroll container does not share the frame id, so upsert reaches it" do
    get fd_case_chat_log_path(@kase, thread: @kase.reports.first&.id)

    assert_equal 1, response.body.scan(/id="chat-log-#{@kase.id}"/).size,
      "the frame id must not be reused by the scroll container"
    assert_includes response.body, %(id="chat-messages-#{@kase.id}" class="chatscroll")
  end

  test "the live stream upserts into the scroll container, not the frame" do
    post fd_case_chats_path(@kase), params: { body: "meow" }, as: :turbo_stream
    get fd_case_chat_log_path(@kase, since: "0.0.0"), as: :turbo_stream

    assert_response :success
    assert_includes response.body, %(target="chat-messages-#{@kase.id}")
  end

  test "asked what changed when nothing did, the log says nothing" do
    get fd_case_chat_log_path(@kase, since: Fd::ChatVersion.for(@kase.id)), as: :turbo_stream
    assert_response :no_content
  end

  test "a reply that went out is taken off the log" do
    conversation = with_a_reporter
    row = Fd::IntakeOutbox.create!(conversation_id: conversation.id, kind: "reply",
      body: "hold on", mode: "signed", requested_by: "UME")
    before = Fd::ChatVersion.for(@kase.id)
    row.update!(sent_at: Time.current)

    get fd_case_chat_log_path(@kase, since: before), as: :turbo_stream

    assert_response :success
  end

  test "a since it cannot read gets the whole log as one upsert" do
    get fd_case_chat_log_path(@kase, since: "garbage"), as: :turbo_stream

    assert_response :success
  end

  def rich(elements)
    [{ "type" => "rich_text",
       "elements" => [{ "type" => "rich_text_section", "elements" => elements }] }]
  end

  test "a line that came from slack is drawn from its blocks" do
    Fd::CaseChat.create!(case_id: @kase.id, author_user_id: "UME", body: "_was_ it",
      source_app: "nemo", channel_id: "CLOG", ts: "1.1",
      blocks: rich([{ "type" => "text", "text" => "was", "style" => { "italic" => true } },
                    { "type" => "text", "text" => " it" }]))

    get fd_case_chat_log_path(@kase, thread: @kase.reports.first&.id)

    assert_includes response.body, "<em>was</em>"
    assert_not_includes response.body, "_was_ it"
  end

  test "a mention in a slack line still links to the member" do
    Fd::CaseChat.create!(case_id: @kase.id, author_user_id: "UME", body: "<@UTHEM> look",
      source_app: "nemo", channel_id: "CLOG", ts: "1.2",
      blocks: rich([{ "type" => "user", "user_id" => "UTHEM" }]))

    get fd_case_chat_log_path(@kase, thread: @kase.reports.first&.id)

    assert_select "a.mention[href=?]", fd_member_path("UTHEM")
  end

  test "a line with no blocks is still drawn from its text" do
    Fd::CaseChat.create!(case_id: @kase.id, author_user_id: "UME", body: "typed here",
      source_app: "fire_engine")

    get fd_case_chat_log_path(@kase, thread: @kase.reports.first&.id)

    assert_includes response.body, "typed here"
  end

  test "a deletion sends the browser back for a full reload" do
    line = Fd::CaseChat.create!(case_id: @kase.id, author_user_id: "UME", body: "oops",
      source_app: "fire_engine")
    before = Fd::ChatVersion.for(@kase.id)
    line.destroy!

    get fd_case_chat_log_path(@kase, since: before), as: :turbo_stream
    assert_response :reset_content
  end

  test "the message is kept as working chat, not as a note" do
    post fd_case_chats_path(@kase), params: { body: "who wants this one?" },
      as: :turbo_stream

    chat = Fd::CaseChat.where(case_id: @kase.id).sole
    assert_equal "who wants this one?", chat.body
    assert_equal "UME", chat.author_user_id
    assert_nil chat.ts, "typed here, so it has not been to Slack yet"
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

  test "a reply with nobody to reply to says so" do
    post fd_case_replies_path(@kase), params: { body: "was this in DMs?" }

    assert_equal 0, Fd::IntakeOutbox.count
    assert_match(/nobody to reply to/, flash[:alert])
  end

  def with_a_reporter
    reporter = Fd::Member.first.user_id
    report = Fd::CaseReport.create!(case_id: @kase.id, reporter_user_id: reporter,
      is_anonymous: false, body: "look at this", source_app: "relay", received_at: 2.days.ago)
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
    ENV["INTERNAL_LOG_CHANNEL_ID"] = "C0FIRE"
    Fd::CaseReport.create!(case_id: @kase.id, is_anonymous: true, source_app: "relay",
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

    chat = instead_of(:post_message, answer) { say }

    assert_equal "1700.0009", chat.mirrored_ts
    assert_equal "user", chat.mirrored_as
    assert_not_nil chat.mirrored_at
    assert_equal "C0FIRE", sent[:channel]
    assert_equal "1700.0001", sent[:thread_ts], "it lands in the case thread, not the channel"
    assert_equal "xoxp-real", sent[:token]
    assert_equal "did we warn them before?", sent[:text]
    assert_not_nil Fd::StaffSlack.held_by("UME").last_used_at
  ensure
    ENV.delete("INTERNAL_LOG_CHANNEL_ID")
  end

  test "slack refusing it hands the message back to the bot and says why" do
    in_the_firehouse
    refusal = ->(**) { { "ok" => false, "error" => "not_in_channel" } }

    chat = instead_of(:post_message, refusal) { say }

    assert_nil chat.mirrored_ts, "nothing was sent, so nemo still has to carry it"
    assert_nil chat.mirrored_as
    assert_equal "not_in_channel", Fd::StaffSlack.held_by("UME").last_error
  ensure
    ENV.delete("INTERNAL_LOG_CHANNEL_ID")
  end

  test "a dead token is given up on, not tried again for every message" do
    in_the_firehouse
    dead = ->(**) { { "ok" => false, "error" => "token_revoked" } }

    chat = instead_of(:post_message, dead) { say }

    assert_nil chat.mirrored_as
    assert_nil Fd::StaffSlack.held_by("UME"), "it stops claiming messages it cannot send"
    row = Fd::StaffSlack.find_by(staff_user_id: "UME")
    assert row.given_up?
    assert_equal "token_revoked", row.last_error
  ensure
    ENV.delete("INTERNAL_LOG_CHANNEL_ID")
  end

  test "slack being unreachable hands the message back to the bot" do
    in_the_firehouse
    dead = ->(**) { raise Slack::Chat::UnavailableError, "execution expired" }

    chat = instead_of(:post_message, dead) { say }

    assert_nil chat.mirrored_as
    assert_match(/execution expired/, Fd::StaffSlack.held_by("UME").last_error)
  ensure
    ENV.delete("INTERNAL_LOG_CHANNEL_ID")
  end

  test "without slack linked, the message is left for the bot untouched" do
    ENV["INTERNAL_LOG_CHANNEL_ID"] = "C0FIRE"
    Fd::CaseReport.create!(case_id: @kase.id, is_anonymous: true, source_app: "relay",
      received_at: 2.days.ago, forwarded_ts: "1700.0001")

    chat = instead_of(:post_message, ->(**) { flunk "nothing should be sent" }) { say }

    assert_nil chat.mirrored_as
    assert_nil chat.mirrored_ts
  ensure
    ENV.delete("INTERNAL_LOG_CHANNEL_ID")
  end

  test "a case with no card in the firehouse is left for the bot" do
    ENV["INTERNAL_LOG_CHANNEL_ID"] = "C0FIRE"
    Fd::StaffSlack.keep!("UME", token: "xoxp-real", team_id: "T0FIRE", scopes: "chat:write")

    chat = instead_of(:post_message, ->(**) { flunk "there is no thread to post into" }) { say }

    assert_nil chat.mirrored_as
  ensure
    ENV.delete("INTERNAL_LOG_CHANNEL_ID")
  end

  test "a mention survives, the rest is escaped for slack" do
    assert_equal "&lt;b&gt; <@U0A1> &amp; me",
      Fd::SlackPost.escape_markup("<b> <@U0A1> & me")
  end
end
