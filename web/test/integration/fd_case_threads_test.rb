require "test_helper"

class FdCaseThreadsTest < ActionDispatch::IntegrationTest
  LOUNGE = "C0LOUNGE".freeze
  FIREHOUSE = "GTESTFIRE".freeze
  ROOT_TS = "1762790400.123456".freeze
  LINK = "https://hackclub.slack.com/archives/#{LOUNGE}/p1762790400123456".freeze

  setup do
    @boss = grant_role!("UTHREADBOSS", "community_manager")
    @kase = make_case
  end

  def add(link = LINK, kase: @kase)
    post fd_case_threads_path(kase), params: { link: link }
  end

  def threads(kase = @kase)
    Fd::CaseThread.where(case_id: kase.id)
  end

  def thread!(kase: @kase, channel_id: LOUNGE, thread_ts: ROOT_TS, **attrs)
    Fd::CaseThread.create!({ case_id: kase.id, channel_id: channel_id, thread_ts: thread_ts,
                             added_by: "UMOD", added_at: 1.day.ago }.merge(attrs))
  end

  def frame_id(thread)
    ActionView::RecordIdentifier.dom_id(thread, :row)
  end

  def stub_slack_message(result)
    calls = []
    original_at = Slack::Message.method(:at)
    Slack::Message.define_singleton_method(:at) do |channel_id, ts, thread_ts: nil|
      calls << [channel_id, ts, thread_ts]
      result
    end
    yield calls
  ensure
    Slack::Message.define_singleton_method(:at, original_at)
  end

  test "add signed out redirects to login and stores nothing" do
    add

    assert_redirected_to login_path
    assert_equal 0, threads.count
  end

  test "add stores the thread as evidence with who added it and audits it on the case" do
    sign_in_as(@boss)
    add

    thread = threads.sole
    assert_equal [LOUNGE, ROOT_TS], thread.coordinates
    assert_equal "evidence", thread.kind
    assert_equal "UTHREADBOSS", thread.added_by
    assert_not thread.is_primary
    assert_redirected_to fd_case_path(@kase, tab: "threads")
    assert_equal "Slack thread added", flash[:notice]
    entry = Fd::AuditEntry.find_by!(entity_type: "thread", verb: "attached", entity_id: @kase.id)
    assert_equal({ "case_id" => @kase.id, "channel_id" => LOUNGE, "thread_ts" => ROOT_TS, "kind" => "evidence" },
      entry.after)
  end

  test "add from a reply link stores the thread the reply belongs to" do
    sign_in_as(@boss)
    add("https://hackclub.slack.com/archives/#{LOUNGE}/p1762790999000100?thread_ts=#{ROOT_TS}&cid=#{LOUNGE}")

    assert_equal ROOT_TS, threads.sole.thread_ts
  end

  test "add of a thread in an FD channel stores it as internal" do
    Fd::AppSetting.set_firehouse_channel(FIREHOUSE, by: "UTHREADBOSS")
    sign_in_as(@boss)
    add("https://hackclub.slack.com/archives/#{FIREHOUSE}/p1762790400123456")

    assert_equal "internal", threads.sole.kind
  end

  test "add with a link that is not a Slack message is refused with a field error" do
    sign_in_as(@boss)
    add("https://example.com/archives/#{LOUNGE}/p1762790400123456")

    assert_equal 0, threads.count
    assert_redirected_to fd_case_path(@kase, tab: "threads", do: "thread")
    assert_equal "Not a Slack message link", flash[:field_error]["message"]
  end

  test "add with a blank link asks for one" do
    sign_in_as(@boss)
    add("  ")

    assert_equal 0, threads.count
    assert_equal "Enter a Slack link", flash[:field_error]["message"]
  end

  test "add of a thread already on the case is refused" do
    sign_in_as(@boss)
    add
    add

    assert_equal 1, threads.count
    assert_equal "Thread already on this case", flash[:alert]
  end

  test "add of a thread already on a case merged into this one is refused" do
    merged = make_case(duplicate_of: @kase.id, resolved_at: Time.current, resolution: "duplicate")
    thread!(kase: merged)
    sign_in_as(@boss)
    add

    assert_equal 0, threads.count
    assert_equal "Thread already on this case", flash[:alert]
  end

  test "remove hides the thread, keeps the row and offers undo" do
    thread = thread!
    sign_in_as(@boss)
    delete fd_case_thread_path(@kase, thread)

    thread.reload
    assert thread.removed?
    assert_equal "UTHREADBOSS", thread.removed_by
    assert_redirected_to fd_case_path(@kase, tab: "threads")
    assert_equal "Slack thread removed", flash[:notice]
    assert_equal({ "link" => LINK }, flash[:action]["params"])
    assert Fd::AuditEntry.exists?(entity_type: "thread", verb: "detached", entity_id: @kase.id)
  end

  test "undo restores the removed row with its original adder" do
    thread = thread!(added_by: "U0852GV4XBQ")
    sign_in_as(@boss)
    delete fd_case_thread_path(@kase, thread)
    add

    thread.reload
    assert_not thread.removed?
    assert_nil thread.removed_by
    assert_equal "U0852GV4XBQ", thread.added_by
    assert_equal 1, threads.count
  end

  test "remove of a thread on an unrelated case is refused" do
    other = make_case(subject: "UOTHER")
    thread = thread!(kase: other)
    sign_in_as(@boss)
    delete fd_case_thread_path(@kase, thread)

    assert_not thread.reload.removed?
    assert_equal "Thread not on this case", flash[:alert]
  end

  test "remove of a thread on a case merged into this one works from the main case" do
    merged = make_case(duplicate_of: @kase.id, resolved_at: Time.current, resolution: "duplicate")
    thread = thread!(kase: merged)
    sign_in_as(@boss)
    delete fd_case_thread_path(@kase, thread)

    assert thread.reload.removed?
    assert Fd::AuditEntry.exists?(entity_type: "thread", verb: "detached", entity_id: merged.id)
  end

  test "a firefighter can add and remove threads" do
    sign_in_as(grant_role!("UTHREADFF", "firefighter"))
    add
    delete fd_case_thread_path(@kase, threads.sole)

    assert threads.sole.removed?
  end

  test "an account without case access cannot add or remove threads" do
    thread = thread!(channel_id: "C0SHIP")
    sign_in_as(grant_role!("UTHREADGARDENER", "gardener"))
    add
    delete fd_case_thread_path(@kase, thread)

    assert_equal [thread.id], threads.ids
    assert_not thread.reload.removed?
  end

  test "threads tab lists visible threads of the case family with lazy Slack frames" do
    merged = make_case(duplicate_of: @kase.id, resolved_at: Time.current, resolution: "duplicate")
    shown = thread!
    from_merged = thread!(kase: merged, channel_id: "C0SHIP", thread_ts: "1762790500.000100")
    removed = thread!(channel_id: "C0META", thread_ts: "1762790600.000100", removed_at: Time.current,
      removed_by: "UMOD")
    sign_in_as(@boss)
    get fd_case_path(@kase, tab: "threads")

    assert_response :success
    sources = css_select("turbo-frame[src]").map { |frame| frame["src"] }
    assert_includes sources, fd_case_thread_path(@kase, shown)
    assert_includes sources, fd_case_thread_path(@kase, from_merged)
    assert_not_includes sources, fd_case_thread_path(@kase, removed)
    assert_select "a.view[aria-current=true]", text: /Slack threads\s*2/
    assert_select "turbo-frame.case-thread##{frame_id(shown)}" do
      assert_select "a[href=?]", LINK, text: "Open in Slack"
      assert_select ".sub time", text: "10 Nov 2025, 16:00"
      assert_select "form[action=?]", fd_case_thread_path(@kase, shown)
    end
    assert_select ".case-threads", text: /Added by/, count: 0
  end

  test "threads tab without threads shows the empty title" do
    sign_in_as(@boss)
    get fd_case_path(@kase, tab: "threads")

    assert_select ".empty-title", text: "No Slack threads"
  end

  test "thread frame shows the first message of the thread from Slack" do
    thread = thread!
    message = { "ts" => ROOT_TS, "user" => "UAUTHOR", "text" => "first message in the lounge" }
    sign_in_as(@boss)

    stub_slack_message(Slack::Message::Result.new(message: message)) do |calls|
      get fd_case_thread_path(@kase, thread)

      assert_equal [[LOUNGE, ROOT_TS, nil]], calls
    end

    assert_response :success
    assert_select "turbo-frame##{frame_id(thread)}" do
      assert_select ".msg-text", text: /first message in the lounge/
      assert_select ".sub a[href=?]", fd_member_path("UAUTHOR")
      assert_select ".sub time", text: "10 Nov 2025, 16:00"
      assert_select "form[action=?]", fd_case_thread_path(@kase, thread)
    end
  end

  test "thread frame for a deleted Slack message reads Message unavailable" do
    thread = thread!
    sign_in_as(@boss)

    stub_slack_message(Slack::Message::Result.new(error: :not_found)) do
      get fd_case_thread_path(@kase, thread)
    end

    assert_select "turbo-frame##{frame_id(thread)} .msg-text", text: "Message unavailable"
  end

  test "thread frame for a removed thread is not found" do
    thread = thread!(removed_at: Time.current, removed_by: "UMOD")
    sign_in_as(@boss)
    get fd_case_thread_path(@kase, thread)

    assert_response :not_found
  end

  test "timeline shows a thread added and later removed" do
    sign_in_as(@boss)
    add
    delete fd_case_thread_path(@kase, threads.sole)
    get fd_case_path(@kase, tab: "timeline")

    assert_select ".evrow .msg-who", text: "Slack thread added"
    assert_select ".evrow .msg-who", text: "Slack thread removed"
  end

  test "timeline leaves out a thread added to another case under a matching audit id" do
    other = make_case(subject: "UOTHER")
    Fd::AuditEntry.create!(actor_user_id: "URELAY", actor_kind: "human", entity_type: "thread",
      entity_id: @kase.id, verb: "attached", source_app: "relay",
      after: { "case_id" => other.id, "channel_id" => "C0SHIP", "thread_ts" => "1.1" })
    sign_in_as(@boss)
    get fd_case_path(@kase, tab: "timeline")

    assert_select ".evrow .msg-who", text: "Slack thread added", count: 0
  end

  test "a removed thread stays removed when the LYLA import inserts it again" do
    thread = thread!(removed_at: Time.current, removed_by: "UMOD")

    ActiveRecord::Base.connection.exec_query(<<~SQL.squish, "lyla import", [@kase.id, LOUNGE, ROOT_TS])
      INSERT INTO fd.case_threads (case_id, channel_id, thread_ts, is_primary, added_by, added_at, kind)
      VALUES ($1, $2, $3, false, 'U0852GV4XBQ', now(), 'evidence')
      ON CONFLICT (case_id, channel_id, thread_ts) DO NOTHING
    SQL

    assert_equal [thread.id], threads.ids
    assert thread.reload.removed?
  end
end
