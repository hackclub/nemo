require "test_helper"

class Fd::MarksTest < ActiveSupport::TestCase
  def read(body, **options)
    Fd::Marks.read(body, **options)
  end

  test "read of plain text is not to_reporter and not signed" do
    read = read("did we warn them before?")
    assert_not read.to_reporter?
    assert_not read.signed?
    assert_equal "did we warn them before?", read.body
  end

  test "read strips leading ? and sets to_reporter and signed mode" do
    read = read("?we are looking at it")
    assert read.to_reporter?
    assert read.signed?
    assert_equal "signed", read.mode
    assert_equal "we are looking at it", read.body
  end

  test "read with leading > is to_reporter and strips the prefix" do
    read = read("> we are looking at it")
    assert read.to_reporter?
    assert_equal "we are looking at it", read.body
  end

  test "read with leading ~? is to_reporter and unsigned with body mode" do
    read = read("~?we are looking at it")
    assert read.to_reporter?
    assert_not read.signed?
    assert_equal "body", read.mode
    assert_equal "we are looking at it", read.body
  end

  test "read with leading ~ only is not to_reporter and keeps the body" do
    read = read("~hi team")
    assert_not read.to_reporter?
    assert_equal "~hi team", read.body
  end

  test "read with ?~ is signed and keeps ~ in the body" do
    read = read("?~hi there")
    assert read.to_reporter?
    assert read.signed?, "only a tilde in front of the aim means anonymous"
    assert_equal "~hi there", read.body
  end

  test "read ignores a ? that is not at the start" do
    read = read("is this a ? mark")
    assert_not read.to_reporter?
    assert_equal "is this a ? mark", read.body
  end

  test "read trims whitespace before and after the ? prefix" do
    read = read("  ?   we are on it")
    assert read.to_reporter?
    assert_equal "we are on it", read.body
  end

  test "read with to_reporter option treats leading ~ as unsigned" do
    read = read("~we are on it", to_reporter: true)
    assert read.to_reporter?
    assert_not read.signed?
    assert_equal "we are on it", read.body
  end

  test "read with to_reporter option treats plain text as signed" do
    read = read("we are on it", to_reporter: true)
    assert read.to_reporter?
    assert read.signed?
    assert_equal "we are on it", read.body
  end

  test "read of empty body is not to_reporter and has an empty body" do
    read = read("")
    assert_not read.to_reporter?
    assert_equal "", read.body
  end

  test "read of ? alone is to_reporter with an empty body" do
    read = read("?")
    assert read.to_reporter?
    assert_equal "", read.body
  end

  test "resolve_command? matches the slack resolve forms" do
    ["?resolve", "~?resolve", "!resolve", "? Resolve ", "!  RESOLVE"].each do |body|
      assert Fd::Marks.resolve_command?(body), body
    end
    assert Fd::Marks.resolve_command?("resolve", to_reporter: true)
  end

  test "resolve_command? ignores other text" do
    ["resolve", "?resolve this", "please resolve", "!resolved"].each do |body|
      assert_not Fd::Marks.resolve_command?(body), body
    end
    assert_not Fd::Marks.resolve_command?("resolve later", to_reporter: true)
  end
end
