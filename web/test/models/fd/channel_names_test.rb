require "test_helper"

class Fd::ChannelNamesTest < ActiveSupport::TestCase
  include SeedsPipelineTables

  def named_channel!(channel_id, name, visibility: "public")
    as_pipeline(<<~SQL.squish,
      INSERT INTO raw.channel_dim (channel_id, name, visibility)
      VALUES (?, ?, ?)
      ON CONFLICT (channel_id) DO UPDATE SET name = EXCLUDED.name, visibility = EXCLUDED.visibility
    SQL
      channel_id, name, visibility)
    seeded!("raw.channel_dim", "channel_id", channel_id)
  end

  def private_unnamed_channel!(channel_id)
    as_pipeline(<<~SQL.squish,
      INSERT INTO raw.channel_dim (channel_id, name, visibility)
      VALUES (?, NULL, 'private')
      ON CONFLICT (channel_id) DO UPDATE SET name = NULL, visibility = 'private'
    SQL
      channel_id)
    seeded!("raw.channel_dim", "channel_id", channel_id)
  end

  test "a named channel shows its name" do
    named_channel!("C0NAMED000", "the-lounge")
    names = Fd::ChannelNames.for(["C0NAMED000"])

    assert_equal "#the-lounge", names["C0NAMED000"]
    assert names.named?("C0NAMED000")
    assert_not names.private_unnamed?("C0NAMED000")
  end

  test "a channel we know is private and have no name for is flagged, not shown" do
    private_unnamed_channel!("C0SECRET00")
    names = Fd::ChannelNames.for(["C0SECRET00"])

    assert names.private_unnamed?("C0SECRET00")
    assert_not names.named?("C0SECRET00")
  end

  test "a private channel we already have a name for is not flagged" do
    named_channel!("C0KNOWN000", "the-firehouse", visibility: "private")
    names = Fd::ChannelNames.for(["C0KNOWN000"])

    assert_equal "#the-firehouse", names["C0KNOWN000"]
    assert_not names.private_unnamed?("C0KNOWN000")
  end

  test "a channel we have never seen is neither named nor flagged private" do
    names = Fd::ChannelNames.for(["C0NEVERSEEN"])

    assert_not names.named?("C0NEVERSEEN")
    assert_not names.private_unnamed?("C0NEVERSEEN")
    assert_equal "C0NEVERSEEN", names["C0NEVERSEEN"]
  end

  test "none answers every question without a query" do
    names = Fd::ChannelNames.none

    assert_not names.named?("C0ANYTHING")
    assert_not names.private_unnamed?("C0ANYTHING")
  end
end
