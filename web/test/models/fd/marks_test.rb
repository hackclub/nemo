require "test_helper"

class Fd::MarksTest < ActiveSupport::TestCase
  def read(body, **options)
    Fd::Marks.read(body, **options)
  end

  test "a plain message stays with the team" do
    said = read("did we warn them before?")
    assert_not said.to_reporter?
    assert_not said.signed?
    assert_equal "did we warn them before?", said.said
  end

  test "a question mark aims it at the reporter, with your name on it" do
    said = read("?we are looking at it")
    assert said.to_reporter?
    assert said.signed?
    assert_equal "signed", said.mode
    assert_equal "we are looking at it", said.said
  end

  test "the old angle bracket still works" do
    said = read("> we are looking at it")
    assert said.to_reporter?
    assert_equal "we are looking at it", said.said
  end

  test "a tilde in front takes your name off it" do
    said = read("~?we are looking at it")
    assert said.to_reporter?
    assert_not said.signed?
    assert_equal "body", said.mode
    assert_equal "we are looking at it", said.said
  end

  test "a tilde on its own is just text, because the team always sees you" do
    said = read("~hi team")
    assert_not said.to_reporter?
    assert_equal "~hi team", said.said
  end

  test "a tilde after the aim is not a mark, it is what you are sending" do
    said = read("?~hi there")
    assert said.to_reporter?
    assert said.signed?, "only a tilde in front of the aim means anonymous"
    assert_equal "~hi there", said.said
  end

  test "a mark only counts at the very start" do
    said = read("is this a ? mark")
    assert_not said.to_reporter?
    assert_equal "is this a ? mark", said.said
  end

  test "leading space before the mark is fine, and the space after is eaten" do
    said = read("  ?   we are on it")
    assert said.to_reporter?
    assert_equal "we are on it", said.said
  end

  test "when the destination is already known, a bare tilde means anonymous" do
    said = read("~we are on it", aimed: true)
    assert said.to_reporter?
    assert_not said.signed?
    assert_equal "we are on it", said.said
  end

  test "when the destination is already known, plain text is signed" do
    said = read("we are on it", aimed: true)
    assert said.to_reporter?
    assert said.signed?
    assert_equal "we are on it", said.said
  end

  test "an empty body reads as nothing aimed anywhere" do
    said = read("")
    assert_not said.to_reporter?
    assert_equal "", said.said
  end

  test "a mark with nothing after it is still a mark" do
    said = read("?")
    assert said.to_reporter?
    assert_equal "", said.said
  end
end
