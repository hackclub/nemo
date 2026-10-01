require "test_helper"

class MessageFilesTest < ActionDispatch::IntegrationTest
  PNG = "\x89PNG\r\n\x1a\n".b.freeze
  FILE_ID = "F1SHOT".freeze

  SAID = {
    "text" => "look at this",
    "files" => [{ "id" => FILE_ID, "name" => "shot.png", "mimetype" => "image/png",
                  "url_private" => "https://files.slack.com/files-pri/T1-F1/shot.png" },
                { "id" => "F2DOC", "name" => "notes.pdf", "mimetype" => "application/pdf",
                  "url_private" => "https://files.slack.com/files-pri/T1-F2/notes.pdf" }]
  }.freeze

  setup do
    @post = Analytics::FctMessage.where(is_reply: false, subtype: nil)
      .where.not(author_id: nil).where("author_id ~ '^[UW]'").order(posted_at: :desc).first
    skip "the tiny seed holds no top-level post" if @post.nil?

    @me = Account.find_or_create_by!(user_id: @post.author_id)
    Rails.cache.clear
  end

  teardown do
    Channels::Activity::Setting.where(channel_id: @post&.channel_id).delete_all
  end

  def shown!
    Channels::Activity::Setting.create!(channel_id: @post.channel_id, set_by: "test",
      set_at: Time.current)
  end

  def path_for(file_id = FILE_ID)
    message_file_path(@post.channel_id, @post.ts, file_id)
  end

  def answering(file: nil, said: SAID)
    was_call = Slack::ProxyClient.method(:call)
    was_file = Slack::ProxyClient.method(:file)
    asked = []
    Slack::ProxyClient.define_singleton_method(:call) do |_method, params = {}, **|
      { "ok" => true, "messages" => [said.merge("ts" => params["latest"])] }
    end
    Slack::ProxyClient.define_singleton_method(:file) do |method, params = {}, **|
      asked << [method, params]
      raise Slack::ProxyClient::Unavailable, "proxy returned 503" if file.nil?

      file
    end
    yield asked
  ensure
    Slack::ProxyClient.define_singleton_method(:call, was_call)
    Slack::ProxyClient.define_singleton_method(:file, was_file)
  end

  def a_png = Slack::ProxyClient::Body.new(bytes: PNG, kind: "image/png")

  test "the author gets the bytes, inline, from the proxy" do
    shown!
    sign_in_as(@me)

    answering(file: a_png) do |asked|
      get path_for

      assert_response :success
      assert_equal PNG, response.body
      assert_equal "image/png", response.media_type
      assert_match(/inline/, response.headers["Content-Disposition"])
      assert_match(/private/, response.headers["Cache-Control"])
      assert_equal [["files.read",
                     { "url" => "https://files.slack.com/files-pri/T1-F1/shot.png" }]], asked
    end
  end

  test "a type slack claims is html is never served as html" do
    shown!
    sign_in_as(@me)
    said = SAID.merge("files" => [{ "id" => FILE_ID, "name" => "x.html",
                                    "mimetype" => "text/html",
                                    "url_private" => "https://files.slack.com/x.html" }])

    answering(file: Slack::ProxyClient::Body.new(bytes: "<script>alert(1)</script>",
                                                 kind: "text/html"), said: said) do
      get path_for

      assert_equal "application/octet-stream", response.media_type
      assert_match(/attachment/, response.headers["Content-Disposition"])
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      assert_match(/default-src 'none'/, response.headers["Content-Security-Policy"])
    end
  end

  test "an svg is never rendered inline, whatever slack says it is" do
    shown!
    sign_in_as(@me)
    said = SAID.merge("files" => [{ "id" => FILE_ID, "name" => "x.svg",
                                    "mimetype" => "image/svg+xml",
                                    "url_private" => "https://files.slack.com/x.svg" }])

    answering(file: Slack::ProxyClient::Body.new(bytes: "<svg/>", kind: "image/svg+xml"),
              said: said) do
      get path_for

      assert_match(/attachment/, response.headers["Content-Disposition"])
      assert_equal "application/octet-stream", response.media_type
    end
  end

  test "anything that is not an image comes down as an attachment" do
    shown!
    sign_in_as(@me)

    answering(file: Slack::ProxyClient::Body.new(bytes: "pdf", kind: "application/pdf")) do
      get path_for("F2DOC")

      assert_match(/attachment/, response.headers["Content-Disposition"])
    end
  end

  test "a file that is not on that post is not served" do
    shown!
    sign_in_as(@me)

    answering(file: a_png) do |asked|
      get path_for("F9ELSEWHERE")

      assert_response :not_found
      assert_empty asked, "slack must not be asked for a file the post does not carry"
    end
  end

  test "somebody else is refused" do
    shown!
    sign_in_as(Account.find_or_create_by!(user_id: "UMSGOTHER"))

    answering(file: a_png) do |asked|
      get path_for

      assert_response :forbidden
      assert_empty asked
    end
  end

  test "a channel that does not show activity serves nothing" do
    sign_in_as(@me)

    answering(file: a_png) do |asked|
      get path_for

      assert_response :not_found
      assert_empty asked
    end
  end

  test "a stranger is sent to the door" do
    shown!

    answering(file: a_png) do
      get path_for

      assert_response :redirect
    end
  end

  test "a proxy that will not answer is a bad gateway, not a crash" do
    shown!
    sign_in_as(@me)

    answering(file: nil) do
      get path_for

      assert_response :bad_gateway
    end
  end
end
