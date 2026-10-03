require "test_helper"

class Fd::MarksTest < ActiveSupport::TestCase
  def read(body, **options)
    Fd::Marks.read(body, **options)
  end

  test "a plain message stays with the team" do
    read = read("did we warn them before?")
    assert_not read.to_reporter?
    assert_not read.signed?
    assert_equal "did we warn them before?", read.body
  end

  test "a question mark aims it at the reporter, with your name on it" do
    read = read("?we are looking at it")
    assert read.to_reporter?
    assert read.signed?
    assert_equal "signed", read.mode
    assert_equal "we are looking at it", read.body
  end

  test "the old angle bracket still works" do
    read = read("> we are looking at it")
    assert read.to_reporter?
    assert_equal "we are looking at it", read.body
  end

  test "a tilde in front takes your name off it" do
    read = read("~?we are looking at it")
    assert read.to_reporter?
    assert_not read.signed?
    assert_equal "body", read.mode
    assert_equal "we are looking at it", read.body
  end

  test "a tilde on its own is just text, because the team always sees you" do
    read = read("~hi team")
    assert_not read.to_reporter?
    assert_equal "~hi team", read.body
  end

  test "a tilde after the aim is not a mark, it is what you are sending" do
    read = read("?~hi there")
    assert read.to_reporter?
    assert read.signed?, "only a tilde in front of the aim means anonymous"
    assert_equal "~hi there", read.body
  end

  test "a mark only counts at the very start" do
    read = read("is this a ? mark")
    assert_not read.to_reporter?
    assert_equal "is this a ? mark", read.body
  end

  test "leading space before the mark is fine, and the space after is eaten" do
    read = read("  ?   we are on it")
    assert read.to_reporter?
    assert_equal "we are on it", read.body
  end

  test "when the destination is already known, a bare tilde means anonymous" do
    read = read("~we are on it", aimed: true)
    assert read.to_reporter?
    assert_not read.signed?
    assert_equal "we are on it", read.body
  end

  test "when the destination is already known, plain text is signed" do
    read = read("we are on it", aimed: true)
    assert read.to_reporter?
    assert read.signed?
    assert_equal "we are on it", read.body
  end

  test "an empty body reads as nothing aimed anywhere" do
    read = read("")
    assert_not read.to_reporter?
    assert_equal "", read.body
  end

  test "a mark with nothing after it is still a mark" do
    read = read("?")
    assert read.to_reporter?
    assert_equal "", read.body
  end
end
