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
    Fd::CaseChat.create!(case_id: @kase.id, author_user_id: "UME", body: "on it")
    get fd_case_chat_log_path(@kase)

    assert_response :success
    assert_select "turbo-frame#chat-log-#{@kase.id} .chat-log .said-body", text: "on it"
  end

  test "a reply with nobody to reply to says so" do
    post fd_case_replies_path(@kase), params: { body: "was this in DMs?" }

    assert_equal 0, Fd::IntakeOutbox.count
    assert_match(/nobody to reply to/, flash[:alert])
  end
end
