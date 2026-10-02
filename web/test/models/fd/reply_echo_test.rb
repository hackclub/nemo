require "test_helper"

class Fd::ReplyEchoTest < ActiveSupport::TestCase
  setup do
    @kase = make_case
    reporter = Fd::Member.first.user_id
    @report = Fd::CaseReport.create!(case_id: @kase.id, reporter_user_id: reporter,
      is_anonymous: false, body: "look at this", source_app: "shroud",
      received_at: 2.days.ago, forwarded_ts: "1700.0001")
    @conversation = Fd::IntakeConversation.create!(report_id: @report.id,
      member_user_id: reporter, channel_id: "D0REP", thread_ts: "1700.5",
      opened_at: 2.days.ago)
    ENV["FIREHOUSE_CHANNEL_ID"] = "C0FIRE"
  end

  teardown do
    ENV.delete("FIREHOUSE_CHANNEL_ID")
  end

  def instead_of(answer)
    original = Slack::Chat.method(:post_message)
    Slack::Chat.define_singleton_method(:post_message) do |*args, **kwargs|
      answer.respond_to?(:call) ? answer.call(*args, **kwargs) : answer
    end
    yield
  ensure
    Slack::Chat.define_singleton_method(:post_message, original)
  end

  def queue(mode: "signed", by: "UME", sent: true)
    Fd::IntakeOutbox.create!(conversation_id: @conversation.id, kind: "reply",
      body: "we are looking at it", mode: mode, requested_by: by,
      sent_at: (Time.current if sent))
  end

  def link(user_id = "UME")
    Fd::StaffSlack.keep!(user_id, token: "xoxp-real", team_id: "T0FIRE", scopes: "chat:write")
  end

  test "a sent reply from a linked author is echoed with their own token" do
    link
    queued = queue
    sent = nil

    carried = instead_of(lambda { |**args|
      sent = args
      { "ok" => true, "ts" => "1700.0100" }
    }) { Fd::ReplyEcho.catch_up(@kase.id) }

    assert_equal 1, carried
    assert_equal "xoxp-real", sent[:token]
    assert_equal "C0FIRE", sent[:channel]
    assert_equal "1700.0001", sent[:thread_ts]
    assert_equal "?we are looking at it", sent[:text]
    assert_equal "1700.0100", queued.reload.echoed_ts
    assert_equal "user", queued.echoed_as
  end

  test "an anonymous reply carries both marks so the thread can see which it was" do
    link
    queue(mode: "body")
    sent = nil

    instead_of(lambda { |**args|
      sent = args
      { "ok" => true, "ts" => "1700.0101" }
    }) { Fd::ReplyEcho.catch_up(@kase.id) }

    assert_equal "~?we are looking at it", sent[:text]
  end

  test "an author who never linked is left for the bot" do
    queued = queue

    carried = instead_of(->(**) { flunk "the bot echoes this one" }) {
      Fd::ReplyEcho.catch_up(@kase.id)
    }

    assert_equal 0, carried
    assert_nil queued.reload.echoed_at
  end

  test "a reply that has not gone yet is not echoed" do
    link
    queued = queue(sent: false)

    instead_of(->(**) { flunk "nothing has been sent to the reporter yet" }) {
      Fd::ReplyEcho.catch_up(@kase.id)
    }

    assert_nil queued.reload.echoed_at
  end

  test "the claim means two notifications only echo once" do
    link
    queued = queue
    tries = 0

    instead_of(lambda { |**|
      tries += 1
      { "ok" => true, "ts" => "1700.0102" }
    }) do
      Fd::ReplyEcho.catch_up(@kase.id)
      Fd::ReplyEcho.catch_up(@kase.id)
    end

    assert_equal 1, tries
    assert_equal "1700.0102", queued.reload.echoed_ts
  end

  test "slack refusing it lets the claim go and says why" do
    grant = link
    queued = queue

    instead_of(->(**) { { "ok" => false, "error" => "not_in_channel" } }) do
      Fd::ReplyEcho.catch_up(@kase.id)
    end

    assert_nil queued.reload.echoed_at, "it can be tried again"
    assert_equal "not_in_channel", grant.reload.last_error
  end

  def with_a_failing_write
    Fd::IntakeOutbox.class_eval do
      alias_method :real_update!, :update!
      define_method(:update!) { |*| raise ActiveRecord::StatementInvalid, "connection lost" }
    end
    yield
  ensure
    Fd::IntakeOutbox.class_eval do
      remove_method :update!
      alias_method :update!, :real_update!
      remove_method :real_update!
    end
  end

  test "a write that fails after the post lets the claim go and raises to be retried" do
    grant = link
    queued = queue

    with_a_failing_write do
      instead_of(->(**) { { "ok" => true, "ts" => "1700.0103" } }) do
        assert_raises(ActiveRecord::StatementInvalid) { Fd::ReplyEcho.catch_up(@kase.id) }
      end
    end

    assert_nil queued.reload.echoed_at, "the claim is released so the job can retry"
    assert_nil queued.echoed_ts
    assert_nil grant.reload.last_error, "a database failure is not the grant's fault"
  end

  test "a case with no card in the firehouse echoes nothing" do
    link
    @report.update!(forwarded_ts: nil)
    queued = queue

    instead_of(->(**) { flunk "there is no thread to echo into" }) do
      Fd::ReplyEcho.catch_up(@kase.id)
    end

    assert_nil queued.reload.echoed_at
  end
end
