require "test_helper"

class Fd::ChatChannelsTest < ActiveSupport::TestCase
  Row = Struct.new(:body, :blocks, keyword_init: true)

  test "a row with blocks is read from its blocks" do
    row = Row.new(blocks: [{ "type" => "rich_text", "elements" => [
      { "type" => "rich_text_section", "elements" => [
        { "type" => "channel", "channel_id" => "C0FROMBLOCK" }
      ] }
    ] }])

    assert_equal ["C0FROMBLOCK"], Fd::ChatChannels.ids(row)
  end

  test "a row with no blocks is parsed from its body" do
    row = Row.new(body: "look in <#C0FROMBODY>")

    assert_equal ["C0FROMBODY"], Fd::ChatChannels.ids(row)
  end

  test "ids are deduplicated across every row in every group" do
    rows = [Row.new(body: "<#C0SAME000>"), Row.new(body: "<#C0SAME000> and <#C0OTHER00>")]

    assert_equal %w[C0SAME000 C0OTHER00], Fd::ChatChannels.ids(rows, [nil])
  end

  test "nothing to read makes nothing to ask for" do
    assert_equal [], Fd::ChatChannels.ids([], nil)
  end
end
