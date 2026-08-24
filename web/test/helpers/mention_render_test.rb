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

  test "a labelled mention still becomes a link" do
    said = mentioned("it was <@U0QUINN|old-handle> honestly")
    assert_match(/href="\/fd\/members\/U0QUINN"/, said)
    assert_no_match(/old-handle/, said)
  end

  test "a channel mention becomes a link, never an id" do
    said = mentioned("in <#C0LOUNGE|the-lounge>")
    assert_match(/href="\/channels\/C0LOUNGE"/, said)
    assert_match(/#the-lounge/, said)
  end

  test "a channel with no name at all still says something" do
    assert_match(/C0GONE/, mentioned("in <#C0GONE>"))
  end

  test "plain words are untouched" do
    assert_equal "nothing to see", mentioned("nothing to see")
  end
end
