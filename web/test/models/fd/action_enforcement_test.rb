require "test_helper"

class Fd::ActionEnforcementTest < ActiveSupport::TestCase
  test "the actions table says which kinds nemo can carry" do
    assert_equal "shush", Fd::Action.guard_kind("shush")
    assert_equal "workspace", Fd::Action.guard_scope("shush")
    assert_equal "channel_ban", Fd::Action.guard_kind("channel_ban")
    assert_equal "channel", Fd::Action.guard_scope("channel_ban")
  end

  test "a kind without an enforce block is a record only" do
    %w[warning locked_thread dm].each do |type_key|
      assert_nil Fd::Action.guard_kind(type_key), type_key
      assert_not Fd::Action.enforceable?(type_key), type_key
    end
  end

  test "every ban is carried as a deactivation on the account" do
    %w[temp_ban indef_ban perma_ban].each do |type_key|
      assert_equal Fd::MemberGuard::DEACTIVATION, Fd::Action.guard_kind(type_key), type_key
      assert_equal "account", Fd::Action.guard_scope(type_key), type_key
      assert Fd::Action.enforceable?(type_key), type_key
    end
  end

  test "a kind nobody declared is not enforceable" do
    assert_nil Fd::Action.guard_kind("nonsense")
    assert_not Fd::Action.enforceable?("nonsense")
  end

  test "only the declared kinds are enforceable" do
    assert_equal %w[shush temp_ban indef_ban perma_ban channel_ban].sort,
      Fd::Action::ENFORCEABLE.sort
  end

  test "every enforceable kind names a guard nemo knows" do
    Fd::Action::ENFORCE.each_value do |row|
      assert_includes Fd::MemberGuard::KINDS, row.fetch("guard")
      assert_includes %w[workspace channel account], row.fetch("scope")
      assert_includes %w[reactive applied], row.fetch("carry")
    end
  end

  test "a channel scoped kind is one that already takes a channel" do
    Fd::Action::ENFORCE.each do |type_key, row|
      next unless row["scope"] == "channel"

      assert_includes Fd::Action::TAKES_CHANNEL, type_key
    end
  end
end
