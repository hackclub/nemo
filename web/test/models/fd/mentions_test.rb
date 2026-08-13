require "test_helper"

class Fd::MentionsTest < ActiveSupport::TestCase
  test "a typed handle is stored the way slack writes it" do
    assert_equal "spoke to <@U08K3F2QX> in DM",
      Fd::Mentions.normalise("spoke to @U08K3F2QX in DM")
  end

  test "an id typed without the at sign is still a mention" do
    assert_equal "<@U08K3F2QX> started it", Fd::Mentions.normalise("U08K3F2QX started it")
  end

  test "something already in slack form is left alone, not doubled" do
    already = "spoke to <@U08K3F2QX> in DM"
    assert_equal already, Fd::Mentions.normalise(already)
  end

  test "several mentions in one note all convert" do
    assert_equal "<@U08K3F2QX> and <@W01ABCDEF> were both there",
      Fd::Mentions.normalise("@U08K3F2QX and @W01ABCDEF were both there")
  end

  test "ordinary words that look shouty are not mistaken for members" do
    %w[URGENT UPSET WONT UPPERCASE UNDERSTOOD].each do |word|
      assert_equal word, Fd::Mentions.normalise(word), "#{word} is a word, not a member"
    end
  end

  test "an email address is not chopped into a mention" do
    text = "wrote from UPPERCASE@example.invalid"
    assert_equal text, Fd::Mentions.normalise(text)
  end

  test "the ids can be read back out for looking up names" do
    text = "<@U08K3F2QX> and <@W01ABCDEF> and <@U08K3F2QX> again"
    assert_equal %w[U08K3F2QX W01ABCDEF], Fd::Mentions.ids(text)
  end

  test "nothing in, nothing out" do
    assert_equal "", Fd::Mentions.normalise("")
    assert_nil Fd::Mentions.normalise(nil)
    assert_empty Fd::Mentions.ids(nil)
    assert_empty Fd::Mentions.ids("no mentions here")
  end

  test "splitting keeps the mention and the text either side" do
    assert_equal ["spoke to ", "<@U08K3F2QX>", " in DM"],
      Fd::Mentions.split("spoke to <@U08K3F2QX> in DM")
  end
end
