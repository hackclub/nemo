require "test_helper"

class Fd::SlackLinkTest < ActiveSupport::TestCase
  ROOT = "https://hackclub.slack.com/archives/C0266FRGV/p1754487721123456".freeze

  def parse(url)
    Fd::SlackLink.parse(url)
  end

  test "parse returns channel_id and thread_ts for a top level message link" do
    ref = parse(ROOT)
    assert_equal "C0266FRGV", ref.channel_id
    assert_equal "1754487721.123456", ref.thread_ts
  end

  test "parse returns the thread_ts query value for a reply link" do
    ref = parse("#{ROOT.sub('p1754487721123456', 'p1754487999000200')}" \
      "?thread_ts=1754487721.123456&cid=C0266FRGV")
    assert_equal "1754487721.123456", ref.thread_ts,
      "reply link resolves to the thread root"
  end

  test "parse prefers the thread_ts query over the path timestamp" do
    ref = parse("#{ROOT}?thread_ts=1600000000.000001")
    assert_equal "1600000000.000001", ref.thread_ts
  end

  test "parse uses the path timestamp when thread_ts is malformed" do
    ref = parse("#{ROOT}?thread_ts=nonsense")
    assert_equal "1754487721.123456", ref.thread_ts
  end

  test "parse accepts surrounding whitespace and http" do
    assert_equal "C0266FRGV", parse("  #{ROOT}  ").channel_id
    assert_equal "C0266FRGV", parse(ROOT.sub("https", "http")).channel_id
  end

  test "parse accepts an uppercase host" do
    assert_not_nil parse(ROOT.sub("hackclub.slack.com", "HackClub.Slack.com"))
  end

  test "parse accepts the enterprise host" do
    ref = parse(ROOT.sub("hackclub.slack.com", "hackclub.enterprise.slack.com"))

    assert_equal "C0266FRGV", ref.channel_id
    assert_equal "1754487721.123456", ref.thread_ts
  end

  test "parse returns nil for another workspace host" do
    assert_nil parse(ROOT.sub("hackclub.slack.com", "someoneelse.slack.com"))
  end

  test "parse returns nil for lookalike hosts" do
    assert_nil parse(ROOT.sub("hackclub.slack.com", "hackclub.slack.com.evil.test"))
    assert_nil parse(ROOT.sub("hackclub.slack.com", "evil.test/hackclub.slack.com"))
  end

  test "parse returns nil for non archive paths" do
    assert_nil parse("https://hackclub.slack.com/client/T1/C0266FRGV")
    assert_nil parse("https://hackclub.slack.com/archives/C0266FRGV")
    assert_nil parse("https://hackclub.slack.com/archives/C0266FRGV/p1754487721123456/extra")
  end

  test "parse returns nil for an invalid channel id" do
    assert_nil parse(ROOT.sub("C0266FRGV", "notachannel"))
    assert_nil parse(ROOT.sub("C0266FRGV", "X0266FRGV"))
    assert_nil parse(ROOT.sub("C0266FRGV", "C"))
  end

  test "parse returns nil for an invalid message timestamp" do
    assert_nil parse(ROOT.sub("p1754487721123456", "p123"))
    assert_nil parse(ROOT.sub("p1754487721123456", "1754487721123456"))
    assert_nil parse(ROOT.sub("p1754487721123456", "pabcdefghijklmnop"))
  end

  test "parse returns nil for junk and nil input without raising" do
    ["", "   ", "not a url", "javascript:alert(1)", "//hackclub.slack.com/archives/C1/p1234567",
     "http://", nil].each do |input|
      assert_nil parse(input), "#{input.inspect} should not parse"
    end
  end

  test "url_for rebuilds the original url from a parsed link" do
    ref = parse(ROOT)
    assert_equal ROOT, Fd::SlackLink.url_for(ref.channel_id, ref.thread_ts)
  end

  test "FdHelper slack_thread_url rebuilds the parsed url" do
    ref = parse(ROOT)
    helper = ActionView::Base.empty.extend(FdHelper)
    assert_equal ROOT, helper.slack_thread_url(ref.channel_id, ref.thread_ts)
  end
end
