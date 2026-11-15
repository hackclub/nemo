require "test_helper"

class MentionRenderTest < ActionView::TestCase
  include ApplicationHelper
  include FdHelper

  def channels
    Fd::ChannelNames.none
  end

  def names
    Fd::Names.none
  end

  test "user mention with label renders member link without the label" do
    html = mentioned("it was <@U0QUINN|old-handle> honestly")
    assert_match(/href="\/fd\/members\/U0QUINN"/, html)
    assert_no_match(/old-handle/, html)
  end

  test "case reference in a note links the case next to a member mention" do
    kase = make_case

    html = mentioned("<@U0QUINN> is the same as ##{kase.id}")

    assert_match(%r{href="/fd/members/U0QUINN"}, html)
    assert_includes html, %(<a class="lnk" href="/fd/cases/#{kase.id}">##{kase.id}</a>)
  end

  test "user mention targets the person-drawer turbo frame" do
    html = mentioned("it was <@U0QUINN> honestly")
    assert_match(/data-turbo-frame="person-drawer"/, html)
  end

  test "channel mention renders channel link and channel name" do
    html = mentioned("in <#C0LOUNGE|the-lounge>")
    assert_match(%r{href="/fd/channels/C0LOUNGE"}, html)
    assert_match(/#the-lounge/, html)
  end

  test "channel mention targets the _top turbo frame" do
    html = mentioned("in <#C0LOUNGE|the-lounge>")
    assert_match(/data-turbo-frame="_top"/, html)
  end

  test "channel mention without name renders the channel id" do
    assert_match(/C0GONE/, mentioned("in <#C0GONE>"))
  end

  test "plain text renders unchanged" do
    assert_equal "nothing to see", mentioned("nothing to see")
  end
end
