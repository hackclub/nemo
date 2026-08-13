require "test_helper"

class Fd::NamesTest < ActiveSupport::TestCase
  def profile(name)
    CachetClient::Profile.new(display_name: name, image_url: nil, pronouns: nil)
  end

  test "a known member reads as their name" do
    names = Fd::Names.new("U1" => profile("Ada Lovelace"))
    assert_equal "Ada Lovelace", names["U1"]
  end

  test "an unknown member falls back to the handle rather than going blank" do
    assert_equal "@U1", Fd::Names.new({})["U1"]
  end

  test "a profile with an empty name falls back too" do
    assert_equal "@U1", Fd::Names.new("U1" => profile(""))["U1"]
  end

  test "no id at all reads as n/a" do
    assert_equal "n/a", Fd::Names.none[nil]
    assert_equal "n/a", Fd::Names.none[""]
  end

  test "a list reads as a sentence, mixing known and unknown" do
    names = Fd::Names.new("U1" => profile("Ada"))
    assert_equal "Ada and @U2", names.list(%w[U1 U2])
    assert_equal "Ada", names.list(["U1"])
    assert_equal "", names.list([])
  end
end
