require "test_helper"

class Slack::MrkdwnTest < ActiveSupport::TestCase
  def parts(text)
    Slack::Mrkdwn.blocks(text).first["elements"]
  end

  def inline(text)
    parts(text).first["elements"]
  end

  test "nothing to say makes no blocks at all" do
    assert_equal [], Slack::Mrkdwn.blocks("")
    assert_equal [], Slack::Mrkdwn.blocks(nil)
    assert_equal [], Slack::Mrkdwn.blocks("   \n  ")
  end

  test "every delimiter slack takes becomes a style" do
    assert_equal({ "bold" => true }, inline("*loud*").first["style"])
    assert_equal({ "italic" => true }, inline("_soft_").first["style"])
    assert_equal({ "strike" => true }, inline("~gone~").first["style"])
    assert_equal({ "code" => true }, inline("`puts`").first["style"])
  end

  test "styles nest" do
    found = inline("*_both_*").first

    assert_equal "both", found["text"]
    assert_equal({ "bold" => true, "italic" => true }, found["style"])
  end

  test "a delimiter touching nothing is left as text" do
    assert_equal [{ "type" => "text", "text" => "2 * 3 * 4" }], inline("2 * 3 * 4")
  end

  test "mentions and channels keep their ids" do
    assert_equal({ "type" => "user", "user_id" => "U08EMT46G3V" }, inline("<@U08EMT46G3V>").first)
    assert_equal({ "type" => "channel", "channel_id" => "C0BSBP62C3U" },
      inline("<#C0BSBP62C3U|not-fire-dept>").first)
  end

  test "a wrapped link keeps its label, a bare one stands alone" do
    wrapped = inline("<https://hack.club|the club>").first
    assert_equal({ "type" => "link", "url" => "https://hack.club", "text" => "the club" }, wrapped)

    assert_equal({ "type" => "link", "url" => "https://hack.club" },
      inline("https://hack.club").first)
  end

  test "an emoji keeps its name for the emoji lookup" do
    assert_equal({ "type" => "emoji", "name" => "sho" }, inline("hi :sho:").last)
  end

  test "slack's escaped entities come back as themselves" do
    assert_equal "a > b & c < d", inline("a &gt; b &amp; c &lt; d").first["text"]
  end

  test "a run of quoted lines is one quote block" do
    found = parts("&gt; they said\n&gt; and then\nmine")

    assert_equal "rich_text_quote", found.first["type"]
    assert_equal "they said\nand then", found.first["elements"].first["text"]
    assert_equal "rich_text_section", found.last["type"]
  end

  test "a fence is preformatted and keeps its delimiters literal" do
    found = parts("look:\n```\n*not bold*\n```")

    assert_equal "rich_text_preformatted", found.last["type"]
    assert_equal "*not bold*", found.last["elements"].first["text"]
  end

  test "inline code is never parsed for styles inside it" do
    found = inline("`*raw*`").first

    assert_equal "*raw*", found["text"]
    assert_equal({ "code" => true }, found["style"])
  end
end
