require "test_helper"

class Fd::ChatChannelsTest < ActiveSupport::TestCase
  Row = Struct.new(:body, :blocks, keyword_init: true)

  test "ids reads channel ids from row blocks" do
    row = Row.new(blocks: [{ "type" => "rich_text", "elements" => [
      { "type" => "rich_text_section", "elements" => [
        { "type" => "channel", "channel_id" => "C0FROMBLOCK" }
      ] }
    ] }])

    assert_equal ["C0FROMBLOCK"], Fd::ChatChannels.ids(row)
  end

  test "ids parses channel mentions from row body when blocks are nil" do
    row = Row.new(body: "look in <#C0FROMBODY>")

    assert_equal ["C0FROMBODY"], Fd::ChatChannels.ids(row)
  end

  test "ids deduplicates across rows and groups" do
    rows = [Row.new(body: "<#C0SAME000>"), Row.new(body: "<#C0SAME000> and <#C0OTHER00>")]

    assert_equal %w[C0SAME000 C0OTHER00], Fd::ChatChannels.ids(rows, [nil])
  end

  test "ids reads the channel of a message link" do
    row = Row.new(body: "see <https://hackclub.slack.com/archives/C0LINKED0/p1790111676119469>")

    assert_equal ["C0LINKED0"], Fd::ChatChannels.ids(row)
  end

  test "ids returns an empty array for empty rows and nil" do
    assert_equal [], Fd::ChatChannels.ids([], nil)
  end
end
