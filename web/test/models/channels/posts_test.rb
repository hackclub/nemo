require "test_helper"

class Channels::PostsTest < ActiveSupport::TestCase
  setup do
    @row = Analytics::FctMessage.where(is_reply: false, subtype: nil)
      .where.not(author_id: nil).where("author_id ~ '^[UW]'").order(:posted_at).first
    skip "the tiny seed holds no top-level post" if @row.nil?
    @channel_id = @row.channel_id
    @subject_id = @row.author_id
  end

  def mine(shown: Channels::Posts::SHOWN)
    Channels::Posts.rows(channel_id: @channel_id, subject_id: @subject_id, shown: shown)
  end

  test "three posts is what a page holds" do
    assert_equal 3, Channels::Posts::SHOWN
    assert_operator mine.size, :<=, 3
  end

  test "every post belongs to the member asked about" do
    assert mine.all? { |row| row.author_id == @subject_id }
  end

  test "replies are left out, since activity is not counted on them" do
    assert mine.none?(&:is_reply)
  end

  test "newest first" do
    stamps = mine.map(&:posted_at)
    assert_equal stamps.sort.reverse, stamps
  end

  test "another member's posts in the same channel are not theirs to see" do
    other = Analytics::FctMessage.where(channel_id: @channel_id, is_reply: false)
      .where.not(author_id: [@subject_id, nil]).first
    skip "the seed has nobody else in this channel" if other.nil?

    assert Channels::Posts.rows(channel_id: @channel_id, subject_id: other.author_id)
      .none? { |row| row.author_id == @subject_id }
  end

  test "a post in another channel stays there" do
    assert mine.all? { |row| row.channel_id == @channel_id }
  end

  Viewer = Struct.new(:user_id)

  test "only your own, until somebody is given more" do
    assert Channels::Posts.may_read?(Viewer.new("U1"), "U1")
    assert_not Channels::Posts.may_read?(Viewer.new("U1"), "U2")
    assert_not Channels::Posts.may_read?(nil, "U1")
    assert_not Channels::Posts.may_read?(Viewer.new("U1"), nil)
  end

  Row = Struct.new(:channel_id, :ts, :author_id, :posted_at, :reply_count, :reaction_count)

  def given(rows, answer)
    was = Channels::Posts.method(:rows)
    Channels::Posts.define_singleton_method(:rows) { |**| rows }
    told = Slack::Message.method(:at)
    Slack::Message.define_singleton_method(:at) { |channel_id, ts| answer.call(channel_id, ts) }
    yield
  ensure
    Channels::Posts.define_singleton_method(:rows, was)
    Slack::Message.define_singleton_method(:at, told)
  end

  def a_row(ts = "1790701062.123456")
    Row.new("C1", ts, "U1", Time.current, 2, 5)
  end

  test "what a post said is read back from slack, one post at a time" do
    asked = []
    found = Slack::Message::Result.new(said: { "text" => "big news" })

    given([a_row], ->(channel_id, ts) { asked << [channel_id, ts]; found }) do
      posts = Channels::Posts.for(channel_id: "C1", subject_id: "U1")

      assert_equal [["C1", "1790701062.123456"]], asked
      assert_equal "big news", posts.sole.message["text"]
      assert_equal 2, posts.sole.replies
      assert_equal 5, posts.sole.reactions
      assert_equal "U1", posts.sole.author_id
    end
  end

  test "a post slack no longer has is dropped without a word" do
    given([a_row], ->(*) { Slack::Message::Result.new(error: :not_found) }) do
      assert_empty Channels::Posts.for(channel_id: "C1", subject_id: "U1")
    end
  end

  test "a post slack could not answer for is kept, so the page can say so" do
    given([a_row], ->(*) { Slack::Message::Result.new(error: :unavailable) }) do
      posts = Channels::Posts.for(channel_id: "C1", subject_id: "U1")

      assert_equal :unavailable, posts.sole.error
      assert_nil posts.sole.message
    end
  end
end
