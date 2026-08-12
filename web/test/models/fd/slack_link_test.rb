require "test_helper"

class Fd::SlackLinkTest < ActiveSupport::TestCase
  ROOT = "https://hackclub.slack.com/archives/C0266FRGV/p1754487721123456".freeze

  def parse(url)
    Fd::SlackLink.parse(url)
  end

  test "a top level message link gives the channel and the thread root" do
    ref = parse(ROOT)
    assert_equal "C0266FRGV", ref.channel_id
    assert_equal "1754487721.123456", ref.thread_ts
  end

  test "a reply link resolves to the thread it belongs to, not the reply" do
    ref = parse("#{ROOT.sub('p1754487721123456', 'p1754487999000200')}" \
      "?thread_ts=1754487721.123456&cid=C0266FRGV")
    assert_equal "1754487721.123456", ref.thread_ts,
      "pasting a reply must attach the thread, not one message inside it"
  end

  test "the query root wins over the path stamp" do
    ref = parse("#{ROOT}?thread_ts=1600000000.000001")
    assert_equal "1600000000.000001", ref.thread_ts
  end

  test "a malformed query root falls back to the path" do
    ref = parse("#{ROOT}?thread_ts=nonsense")
    assert_equal "1754487721.123456", ref.thread_ts
  end

  test "surrounding whitespace and http are tolerated" do
    assert_equal "C0266FRGV", parse("  #{ROOT}  ").channel_id
    assert_equal "C0266FRGV", parse(ROOT.sub("https", "http")).channel_id
  end

  test "an uppercase host still matches" do
    assert_not_nil parse(ROOT.sub("hackclub.slack.com", "HackClub.Slack.com"))
  end

  test "another workspace is refused" do
    assert_nil parse(ROOT.sub("hackclub.slack.com", "someoneelse.slack.com"))
  end

  test "a lookalike host is refused" do
    assert_nil parse(ROOT.sub("hackclub.slack.com", "hackclub.slack.com.evil.test"))
    assert_nil parse(ROOT.sub("hackclub.slack.com", "evil.test/hackclub.slack.com"))
  end

  test "a path that is not an archive link is refused" do
    assert_nil parse("https://hackclub.slack.com/client/T1/C0266FRGV")
    assert_nil parse("https://hackclub.slack.com/archives/C0266FRGV")
    assert_nil parse("https://hackclub.slack.com/archives/C0266FRGV/p1754487721123456/extra")
  end

  test "a channel id that is not one is refused" do
    assert_nil parse(ROOT.sub("C0266FRGV", "notachannel"))
    assert_nil parse(ROOT.sub("C0266FRGV", "X0266FRGV"))
    assert_nil parse(ROOT.sub("C0266FRGV", "C"))
  end

  test "a stamp that is not a timestamp is refused" do
    assert_nil parse(ROOT.sub("p1754487721123456", "p123"))
    assert_nil parse(ROOT.sub("p1754487721123456", "1754487721123456"))
    assert_nil parse(ROOT.sub("p1754487721123456", "pabcdefghijklmnop"))
  end

  test "junk input returns nothing rather than raising" do
    ["", "   ", "not a url", "javascript:alert(1)", "//hackclub.slack.com/archives/C1/p1234567",
     "http://", nil].each do |input|
      assert_nil parse(input), "#{input.inspect} should not parse"
    end
  end

  test "a parsed link rebuilds into the link it came from" do
    ref = parse(ROOT)
    assert_equal ROOT, Fd::SlackLink.url_for(ref.channel_id, ref.thread_ts)
  end

  test "the helper and the parser agree on the same url" do
    ref = parse(ROOT)
    helper = ActionView::Base.empty.extend(FdHelper)
    assert_equal ROOT, helper.slack_thread_url(ref.channel_id, ref.thread_ts)
  end
end
