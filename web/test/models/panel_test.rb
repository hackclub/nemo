require "test_helper"

class PanelTest < ActiveSupport::TestCase
  test "every panel in the catalogue needs a real capability, or nothing" do
    Panel.keys.each do |key|
      want = Panel.needs(key)
      next if want.nil?

      assert_includes Authz.keys, want, "panel #{key} needs #{want}, which is not a capability"
    end
  end

  test "an open panel is visible to any signed-in member and to nobody else" do
    assert Panel.visible?("overview.team_stats", Account.new(user_id: "UANY"))
    assert_not Panel.visible?("overview.team_stats", nil)
  end

  test "a gated panel stays shut without the capability" do
    bare = Account.new(user_id: "UBARE1")

    assert_not Panel.visible?("members.directory", bare)
  end

  test "an unknown panel is refused rather than treated as open" do
    assert_raises(Panel::Unknown) { Panel.visible?("overview.teleporter", nil) }
  end

  test "the analytics panels are open and the member directory is not" do
    assert Panel.open?("overview.team_stats")
    assert Panel.open?("journey.distribution")
    assert Panel.open?("journey.top_posters")
    assert_nil Panel.needs("journey.top_posters")
    assert_not Panel.open?("members.directory")
    assert_equal "member.read", Panel.needs("members.directory")
  end

  test "top posters is visible to any signed-in member and to nobody else" do
    assert Panel.visible?("journey.top_posters", Account.new(user_id: "UBARE1"))
    assert_not Panel.visible?("journey.top_posters", nil)
  end
end
