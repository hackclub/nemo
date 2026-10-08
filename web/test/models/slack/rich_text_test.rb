require "test_helper"

class Slack::RichTextTest < ActiveSupport::TestCase
  def render(elements, names: {}, channels: {})
    Slack::RichText.for(
      { "blocks" => [{ "type" => "rich_text",
                       "elements" => [{ "type" => "rich_text_section", "elements" => elements }] }] },
      names: names, channels: channels
    )
  end

  test "a plain run of text is a paragraph" do
    assert_equal "<p class=\"richtext-text\">big news</p>",
      render([{ "type" => "text", "text" => "big news" }])
  end

  test "newlines inside one run become breaks" do
    html = render([{ "type" => "text", "text" => "one\ntwo" }])

    assert_match(/one<br>two/, html)
  end

  test "every style slack sends is marked up" do
    html = render([
      { "type" => "text", "text" => "b", "style" => { "bold" => true } },
      { "type" => "text", "text" => "i", "style" => { "italic" => true } },
      { "type" => "text", "text" => "s", "style" => { "strike" => true } },
      { "type" => "text", "text" => "c", "style" => { "code" => true } }
    ])

    assert_match(%r{<strong>b</strong>}, html)
    assert_match(%r{<em>i</em>}, html)
    assert_match(%r{<s>s</s>}, html)
    assert_match(%r{<code class="richtext-code">c</code>}, html)
  end

  test "styles stack on one run" do
    html = render([{ "type" => "text", "text" => "loud",
                     "style" => { "bold" => true, "italic" => true } }])

    assert_match(%r{<em><strong>loud</strong></em>}, html)
  end

  test "a link opens in a new tab and never trusts the scheme" do
    html = render([{ "type" => "link", "url" => "https://hack.af/x", "text" => "here" }])
    assert_match(/href="https:\/\/hack.af\/x"/, html)
    assert_match(/rel="noopener"/, html)

    bare = render([{ "type" => "link", "url" => "javascript:alert(1)", "text" => "no" }])
    assert_no_match(/href/, bare)
  end

  test "a link with no label shows the url" do
    html = render([{ "type" => "link", "url" => "https://hack.af/x" }])

    assert_match(/>https:\/\/hack.af\/x</, html)
  end

  test "an emoji keeps its colons, since slack sends no unicode" do
    assert_match(/:fear:/, render([{ "type" => "emoji", "name" => "fear" }]))
  end

  test "a member reads as a name when one is known, an id when not" do
    html = render([{ "type" => "user", "user_id" => "U1" }], names: { "U1" => "quinn" })
    assert_match(/@quinn/, html)
    assert_no_match(/title=/, html)

    assert_match(/@U2/, render([{ "type" => "user", "user_id" => "U2" }]))
  end

  test "a channel reads as a name when one is known" do
    html = render([{ "type" => "channel", "channel_id" => "C1" }], channels: { "C1" => "lounge" })

    assert_match(/#lounge/, html)
  end

  test "a broadcast reads as the word slack shows" do
    assert_match(/@channel/, render([{ "type" => "broadcast", "range" => "channel" }]))
    assert_match(/@here/, render([{ "type" => "broadcast", "range" => "here" }]))
  end

  test "a quoted message links to it in slack" do
    html = render([{ "type" => "message_mention", "message_ts" => "1790111676.119469",
                     "channel_id" => "C0A1", "text" => "what they said",
                     "url" => "https://hackclub.enterprise.slack.com/archives/C0A1/p1790111676119469" }])

    assert_match(/href="https:\/\/hackclub.enterprise.slack.com/, html)
    assert_match(/what they said/, html)
  end

  test "an unknown element falls back to whatever text it carries" do
    assert_match(/leftovers/, render([{ "type" => "citation", "text" => "leftovers" }]))
  end

  test "a caller can render its own user and channel chips" do
    html = Slack::RichText.for(
      { "blocks" => [{ "type" => "rich_text",
                       "elements" => [{ "type" => "rich_text_section", "elements" => [
                         { "type" => "user", "user_id" => "U1" },
                         { "type" => "channel", "channel_id" => "C1" }
                       ] }] }] },
      user_chip: ->(id) { %(<a href="/m/#{id}">them</a>).html_safe },
      channel_chip: ->(id) { %(<a href="/c/#{id}">there</a>).html_safe }
    )

    assert_match(%r{<a href="/m/U1">them</a>}, html)
    assert_match(%r{<a href="/c/C1">there</a>}, html)
    assert_no_match(/richtext-mention/, html)
  end

  test "markup in a message is escaped, never rendered" do
    html = render([{ "type" => "text", "text" => "<script>alert(1)</script>" }])

    assert_no_match(/<script>/, html)
    assert_match(/&lt;script&gt;/, html)
  end

  def wrapped(part)
    Slack::RichText.for({ "blocks" => [{ "type" => "rich_text", "elements" => [part] }] })
  end

  test "channel_ids walks blocks for every channel element" do
    message = { "blocks" => [{ "type" => "rich_text", "elements" => [
      { "type" => "rich_text_section", "elements" => [
        { "type" => "channel", "channel_id" => "C0ONE000" },
        { "type" => "text", "text" => " and " },
        { "type" => "channel", "channel_id" => "C0TWO000" },
        { "type" => "channel", "channel_id" => "C0ONE000" }
      ] }
    ] }] }

    assert_equal %w[C0ONE000 C0TWO000], Slack::RichText.channel_ids(message)
  end

  test "channel_ids finds nothing in a message with no blocks" do
    assert_equal [], Slack::RichText.channel_ids({ "text" => "just words" })
    assert_equal [], Slack::RichText.channel_ids(nil)
  end

  def row(text) = { "type" => "rich_text_section", "elements" => [{ "type" => "text", "text" => text }] }

  test "a bullet list is a ul, an ordered list an ol" do
    bullets = wrapped({ "type" => "rich_text_list", "style" => "bullet", "elements" => [row("one")] })
    assert_match(%r{<ul class="richtext-list richtext-indent-0"><li>}, bullets)

    ordered = wrapped({ "type" => "rich_text_list", "style" => "ordered", "elements" => [row("one")] })
    assert_match(%r{<ol class="richtext-list richtext-indent-0">}, ordered)
  end

  test "an indented list says how deep it is, within reason" do
    html = wrapped({ "type" => "rich_text_list", "style" => "bullet", "indent" => 99,
                     "elements" => [row("deep")] })

    assert_match(/richtext-indent-5/, html)
  end

  test "an ordered list that starts late says where" do
    html = wrapped({ "type" => "rich_text_list", "style" => "ordered", "offset" => 4,
                     "elements" => [row("five")] })

    assert_match(/start="5"/, html)
  end

  test "a quote is a blockquote and preformatted text is a pre" do
    quote = wrapped({ "type" => "rich_text_quote",
                      "elements" => [{ "type" => "text", "text" => "they said" }] })
    assert_match(%r{<blockquote class="richtext-quote">they said</blockquote>}, quote)

    pre = wrapped({ "type" => "rich_text_preformatted",
                    "elements" => [{ "type" => "text", "text" => "puts 1" }] })
    assert_match(%r{<pre class="richtext-pre"><code>puts 1</code></pre>}, pre)
  end

  test "a message with no blocks falls back to its text" do
    html = Slack::RichText.for({ "text" => "just words" })

    assert_match(/just words/, html)
  end

  test "a message with nothing at all renders nothing" do
    assert_equal "", Slack::RichText.for({})
    assert_equal "", Slack::RichText.for(nil)
  end

  test "a divider is a rule and an unknown block is left out" do
    html = Slack::RichText.for({ "blocks" => [{ "type" => "divider" },
                                              { "type" => "image", "image_url" => "x" }] })

    assert_match(%r{<hr class="richtext-rule">}, html)
    assert_no_match(/image/, html)
  end

  test "a section block renders its text" do
    html = Slack::RichText.for({ "blocks" => [{ "type" => "section",
                                                "text" => { "type" => "mrkdwn", "text" => "hello" } }] })

    assert_match(/hello/, html)
  end
end
