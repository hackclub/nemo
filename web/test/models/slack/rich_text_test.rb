require "test_helper"

class Slack::RichTextTest < ActiveSupport::TestCase
  def render(elements, names: {}, channels: {}, usergroups: {})
    Slack::RichText.for(
      { "blocks" => [{ "type" => "rich_text",
                       "elements" => [{ "type" => "rich_text_section", "elements" => elements }] }] },
      names: names, channels: channels, usergroups: usergroups
    )
  end

  test "for renders a text element as a paragraph" do
    assert_equal "<p class=\"richtext-text\">big news</p>",
      render([{ "type" => "text", "text" => "big news" }])
  end

  test "for renders newlines in a text element as br" do
    html = render([{ "type" => "text", "text" => "one\ntwo" }])

    assert_match(/one<br>two/, html)
  end

  test "for renders the bold italic strike and code styles as markup" do
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

  test "for nests bold and italic styles on one text element" do
    html = render([{ "type" => "text", "text" => "loud",
                     "style" => { "bold" => true, "italic" => true } }])

    assert_match(%r{<em><strong>loud</strong></em>}, html)
  end

  test "for renders an https link with href and rel noopener and omits href for a javascript url" do
    html = render([{ "type" => "link", "url" => "https://hack.af/x", "text" => "here" }])
    assert_match(/href="https:\/\/hack.af\/x"/, html)
    assert_match(/rel="noopener"/, html)

    javascript_html = render([{ "type" => "link", "url" => "javascript:alert(1)", "text" => "no" }])
    assert_no_match(/href/, javascript_html)
  end

  test "for renders a link without text using the url as label" do
    html = render([{ "type" => "link", "url" => "https://hack.af/x" }])

    assert_match(/>https:\/\/hack.af\/x</, html)
  end

  test "for renders an emoji element as its :name:" do
    assert_match(/:fear:/, render([{ "type" => "emoji", "name" => "fear" }]))
  end

  test "for with a standard emoji name renders its unicode character" do
    assert_equal %(<p class="richtext-text"><span class="richtext-emoji-char" title=":skull:">💀</span></p>),
      render([{ "type" => "emoji", "name" => "skull" }])
  end

  test "for with emoji unicode code points renders those code points" do
    assert_match(/👋🏽/, render([{ "type" => "emoji", "name" => "wave", "unicode" => "1f44b-1f3fd" }]))
  end

  test "for with a usergroup mention renders the handle when known and the id otherwise" do
    html = render([{ "type" => "usergroup", "usergroup_id" => "S1" }], usergroups: { "S1" => "fire-department" })

    assert_match(/@fire-department/, html)
    assert_match(/@S2/, render([{ "type" => "usergroup", "usergroup_id" => "S2" }]))
  end

  test "for renders a user mention as @name when known and as @id otherwise" do
    html = render([{ "type" => "user", "user_id" => "U1" }], names: { "U1" => "quinn" })
    assert_match(/@quinn/, html)
    assert_no_match(/title=/, html)

    assert_match(/@U2/, render([{ "type" => "user", "user_id" => "U2" }]))
  end

  test "for renders a channel mention as #name when known" do
    html = render([{ "type" => "channel", "channel_id" => "C1" }], channels: { "C1" => "lounge" })

    assert_match(/#lounge/, html)
  end

  test "for renders broadcast elements as @channel and @here" do
    assert_match(/@channel/, render([{ "type" => "broadcast", "range" => "channel" }]))
    assert_match(/@here/, render([{ "type" => "broadcast", "range" => "here" }]))
  end

  test "for renders a message_mention as a link to its url with its text" do
    html = render([{ "type" => "message_mention", "message_ts" => "1790111676.119469",
                     "channel_id" => "C0A1", "text" => "what they said",
                     "url" => "https://hackclub.enterprise.slack.com/archives/C0A1/p1790111676119469" }])

    assert_match(/href="https:\/\/hackclub.enterprise.slack.com/, html)
    assert_match(/what they said/, html)
  end

  test "for renders a message_mention without a url as a link built from its channel and ts" do
    html = render([{ "type" => "message_mention", "channel_id" => "C0A1",
                     "message_ts" => "1790111676.119469", "thread_ts" => "1790111600.000100" }])

    assert_includes html,
      %(href="https://hackclub.slack.com/archives/C0A1/p1790111676119469?thread_ts=1790111600.000100")
  end

  test "link_urls returns link and message_mention urls once" do
    message = { "blocks" => [{ "type" => "rich_text", "elements" => [
      { "type" => "rich_text_section", "elements" => [
        { "type" => "link", "url" => "https://hackclub.slack.com/archives/C0A1/p1790111676119469" },
        { "type" => "message_mention", "channel_id" => "C0A2", "message_ts" => "1790111700.000100" },
        { "type" => "link", "url" => "https://hackclub.slack.com/archives/C0A1/p1790111676119469" }
      ] }
    ] }] }

    assert_equal ["https://hackclub.slack.com/archives/C0A1/p1790111676119469",
                  "https://hackclub.slack.com/archives/C0A2/p1790111700000100"],
      Slack::RichText.link_urls(message)
  end

  test "for renders an unknown element type using its text" do
    assert_match(/leftovers/, render([{ "type" => "citation", "text" => "leftovers" }]))
  end

  test "for renders user and channel mentions with the user_chip and channel_chip callbacks" do
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

  test "for escapes html in text elements" do
    html = render([{ "type" => "text", "text" => "<script>alert(1)</script>" }])

    assert_not_includes html.downcase, "<script"
    assert_match(/&lt;script&gt;/, html)
  end

  def rich_text_for(part)
    Slack::RichText.for({ "blocks" => [{ "type" => "rich_text", "elements" => [part] }] })
  end

  test "channel_ids returns each channel id once across channel elements" do
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

  test "channel_ids returns empty for a message without blocks and for nil" do
    assert_equal [], Slack::RichText.channel_ids({ "text" => "just words" })
    assert_equal [], Slack::RichText.channel_ids(nil)
  end

  def row(text) = { "type" => "rich_text_section", "elements" => [{ "type" => "text", "text" => text }] }

  test "for renders bullet lists as ul and ordered lists as ol" do
    bullets = rich_text_for({ "type" => "rich_text_list", "style" => "bullet", "elements" => [row("one")] })
    assert_match(%r{<ul class="richtext-list richtext-indent-0"><li>}, bullets)

    ordered = rich_text_for({ "type" => "rich_text_list", "style" => "ordered", "elements" => [row("one")] })
    assert_match(%r{<ol class="richtext-list richtext-indent-0">}, ordered)
  end

  test "for caps list indent at richtext-indent-5" do
    html = rich_text_for({ "type" => "rich_text_list", "style" => "bullet", "indent" => 99,
                     "elements" => [row("deep")] })

    assert_match(/richtext-indent-5/, html)
  end

  test "for renders an ordered list offset as the start attribute" do
    html = rich_text_for({ "type" => "rich_text_list", "style" => "ordered", "offset" => 4,
                     "elements" => [row("five")] })

    assert_match(/start="5"/, html)
  end

  test "for renders rich_text_quote as blockquote and rich_text_preformatted as pre" do
    quote = rich_text_for({ "type" => "rich_text_quote",
                      "elements" => [{ "type" => "text", "text" => "they said" }] })
    assert_match(%r{<blockquote class="richtext-quote">they said</blockquote>}, quote)

    pre = rich_text_for({ "type" => "rich_text_preformatted",
                    "elements" => [{ "type" => "text", "text" => "puts 1" }] })
    assert_match(%r{<pre class="richtext-pre"><code>puts 1</code></pre>}, pre)
  end

  test "for renders the text of a message without blocks" do
    html = Slack::RichText.for({ "text" => "just words" })

    assert_match(/just words/, html)
  end

  test "for returns an empty string for an empty hash and for nil" do
    assert_equal "", Slack::RichText.for({})
    assert_equal "", Slack::RichText.for(nil)
  end

  test "for renders a divider block as hr and omits an unknown block type" do
    html = Slack::RichText.for({ "blocks" => [{ "type" => "divider" },
                                              { "type" => "image", "image_url" => "x" }] })

    assert_match(%r{<hr class="richtext-rule">}, html)
    assert_no_match(/image/, html)
  end

  test "for renders the text of a section block" do
    html = Slack::RichText.for({ "blocks" => [{ "type" => "section",
                                                "text" => { "type" => "mrkdwn", "text" => "hello" } }] })

    assert_match(/hello/, html)
  end
end
