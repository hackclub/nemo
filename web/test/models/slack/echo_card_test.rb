require "test_helper"

class Slack::EchoCardTest < ActiveSupport::TestCase
  BLOCKS = [
    { "type" => "header", "text" => { "type" => "plain_text",
      "text" => "Channel ban from #general until 10 Mar" } },
    { "type" => "context", "elements" => [{ "type" => "mrkdwn",
      "text" => "Against <@USUB> · logged by <@UME>" }] },
    { "type" => "divider" },
    { "type" => "section", "text" => { "type" => "mrkdwn",
      "text" => "> kept posting spam links after being warned twice" } },
    { "type" => "context", "elements" => [{ "type" => "mrkdwn",
      "text" => "*How it was solved:* they stopped once the ban kicked in" }] }
  ].freeze

  test "a block of rich_text alone is not an echo" do
    assert_not Slack::EchoCard.echo?([
      { "type" => "rich_text", "elements" => [] }
    ])
  end

  test "a header, a context or a section marks a block array as an echo" do
    assert Slack::EchoCard.echo?([{ "type" => "header" }])
    assert Slack::EchoCard.echo?([{ "type" => "context" }])
    assert Slack::EchoCard.echo?([{ "type" => "section" }])
  end

  test "an empty or missing blocks array is not an echo" do
    assert_not Slack::EchoCard.echo?(nil)
    assert_not Slack::EchoCard.echo?([])
  end

  test "the header becomes the card's bold lead line" do
    html = Slack::EchoCard.render(BLOCKS)
    assert_match %r{<p class="echo-head">Channel ban from #general until 10 Mar</p>}, html
  end

  test "a divider leaves nothing behind, unlike in a plain slack message" do
    html = Slack::EchoCard.render(BLOCKS)
    assert_no_match(/richtext-rule/, html)
  end

  test "context lines are muted meta, with mentions resolved" do
    html = Slack::EchoCard.render(BLOCKS, names: { "USUB" => "subby", "UME" => "mod" })
    assert_match %r{echo-meta.*Against.*subby.*logged by.*mod}m, html
  end

  test "a quoted section renders as an actual blockquote, not a literal &gt;" do
    html = Slack::EchoCard.render(BLOCKS)
    assert_match(
      %r{<blockquote class="richtext-quote">kept posting spam links after being warned twice</blockquote>},
      html,
    )
    assert_no_match(/&gt;/, html)
  end

  test "the how-it-was-solved footer keeps its bold lead" do
    html = Slack::EchoCard.render(BLOCKS)
    assert_match %r{<strong>How it was solved:</strong> they stopped}, html
  end
end
