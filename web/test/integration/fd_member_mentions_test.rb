require "test_helper"

class FdMemberMentionsTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  MEMBER_ID = "UMENTIONED".freeze
  FIREHOUSE = "GTESTFIRE".freeze
  LOGS = "CTESTLOGS".freeze
  LOUNGE = "CTESTLOUNGE".freeze

  setup do
    @boss = grant_role!("UMENTBOSS", "community_manager")
    sign_in_as(@boss)
    Fd::AppSetting.set_firehouse_channel(FIREHOUSE, by: "UMENTBOSS")
    Fd::AppSetting.write(Fd::AppSetting::LOGS, LOGS, by: "UMENTBOSS")
  end

  def message!(channel_id, ts, mentioned: [MEMBER_ID], author: "UAUTHOR", kind: "member", root: nil,
               deleted: false)
    as_pipeline(<<~SQL.squish, channel_id, ts, Time.at(ts.to_r).utc, author, kind, root,
      INSERT INTO archive.message (channel_id, ts, posted_at, author_id, author_kind, thread_root_ts,
                                   is_reply, mentioned_ids, mention_count, deleted_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, string_to_array(?, ','), ?, ?)
    SQL
      root.present? && root != ts, mentioned.join(","), mentioned.size, (Time.current if deleted))
    seeded!("archive.message", "ts", ts)
  end

  def frame_ids
    css_select("turbo-frame[id^='mention-']").map { |frame| frame["id"] }
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

  test "member mentions tab loads the mention list lazily" do
    get fd_member_path(MEMBER_ID, tab: "mentions")

    assert_select "nav.member-record-tabs a[aria-current=true]", text: /Mentions/
    assert_select %(turbo-frame#member-mentions[src="#{fd_member_mentions_path(MEMBER_ID)}"][loading=lazy])
  end

  test "mentions list shows FD channel mentions newest first without deleted, own or other channel messages" do
    message!(FIREHOUSE, "1790000300.000100")
    message!(LOGS, "1790000200.000100", author: "UBOTUSER", kind: "bot")
    message!(LOUNGE, "1790000250.000100")
    message!(FIREHOUSE, "1790000150.000100", deleted: true)
    message!(FIREHOUSE, "1790000100.000100", author: MEMBER_ID)
    message!(FIREHOUSE, "1790000050.000100", mentioned: ["USOMEONE"])

    get fd_member_mentions_path(MEMBER_ID)

    assert_equal ["mention-#{FIREHOUSE}-1790000300000100", "mention-#{LOGS}-1790000200000100"], frame_ids
    assert_select "turbo-frame#member-mentions[target=_top]"
  end

  test "mentions list follows the configured FD channels" do
    message!(LOGS, "1790000200.000100")
    Fd::AppSetting.where(key: Fd::AppSetting::LOGS).delete_all
    Fd::AppSetting.set_case_react_channels([LOUNGE], by: "UMENTBOSS")
    message!(LOUNGE, "1790000250.000100")

    get fd_member_mentions_path(MEMBER_ID)

    assert_equal ["mention-#{LOUNGE}-1790000250000100"], frame_ids
  end

  test "mentions list marks thread replies and links them to the thread" do
    root = "1790000400.000100"
    reply = "1790000400.000200"
    message!(FIREHOUSE, reply, root: root)

    get fd_member_mentions_path(MEMBER_ID)

    assert_select ".msg-kind", text: "Thread reply"
    assert_select "turbo-frame[src=?]", fd_member_mention_path(MEMBER_ID, FIREHOUSE, reply, thread: root)
    assert_select "a[href=?]", "#{Fd::SlackLink.url_for(FIREHOUSE, reply)}?thread_ts=#{root}&cid=#{FIREHOUSE}"
  end

  test "mentions list pages with Earlier into a nested frame" do
    stamps = (0..Fd::MemberMention::PAGE_ROWS).map { |offset| "#{1_790_000_000 + offset}.000100" }
    stamps.each { |ts| message!(FIREHOUSE, ts) }

    get fd_member_mentions_path(MEMBER_ID)

    assert_equal Fd::MemberMention::PAGE_ROWS, frame_ids.size
    earlier = css_select(".member-mentions-more a").sole
    assert_equal "Earlier", earlier.text
    nested = css_select("turbo-frame[id^='member-mentions-']").sole["id"]

    get earlier["href"]

    assert_equal ["mention-#{FIREHOUSE}-#{stamps.first.delete('.')}"], frame_ids
    assert_select "turbo-frame##{nested}"
    assert_select ".member-mentions-more", false
    assert_select ".empty-title", false
  end

  test "mentions list without mentions shows the empty title" do
    get fd_member_mentions_path(MEMBER_ID)

    assert_select ".empty-title", "No mentions"
  end

  test "mention text loads from Slack with the thread ts" do
    result = Slack::Message::Result.new(message: { "ts" => "1790000400.000200",
                                                   "text" => "keep an eye on this one <@#{MEMBER_ID}>" })

    stub_slack_message(result) do |calls|
      get fd_member_mention_path(MEMBER_ID, FIREHOUSE, "1790000400.000200", thread: "1790000400.000100")

      assert_equal [[FIREHOUSE, "1790000400.000200", "1790000400.000100"]], calls
    end
    assert_select "turbo-frame#mention-#{FIREHOUSE}-1790000400000200", text: /keep an eye on this one/
    assert_select "turbo-frame#mention-#{FIREHOUSE}-1790000400000200 a.mention[href=?]", fd_member_path(MEMBER_ID)
  end

  test "mention text for a deleted Slack message reads Message unavailable" do
    stub_slack_message(Slack::Message::Result.new(error: :not_found)) do
      get fd_member_mention_path(MEMBER_ID, FIREHOUSE, "1790000400.000200")
    end

    assert_select ".msg-gone", "Message unavailable"
  end

  test "mention text outside the FD channels is not fetched" do
    stub_slack_message(Slack::Message::Result.new(message: { "text" => "private" })) do |calls|
      get fd_member_mention_path(MEMBER_ID, LOUNGE, "1790000400.000200")

      assert_response :not_found
      assert_empty calls
    end
  end
end
