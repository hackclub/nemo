require "test_helper"

module Fd
  class FlagTest < ActiveSupport::TestCase
    setup do
      Flag.delete_all
      Current.forget_flags
    end

    teardown do
      Flag.delete_all
      Current.forget_flags
    end

    test "a flag nobody has touched follows the file" do
      assert Flag.on?(:fire_engine)
      assert Flag.on?("analytics")
      assert_equal %w[analytics fire_engine], Flag.showing
    end

    test "the file says true in a word yaml does not read as a boolean key" do
      Flag::KEYS.each do |key|
        row = Flag::TABLE.fetch(key)
        assert row.key?("default"), "#{key} has no default"
        assert_not row.key?(true), "yaml read the key as a boolean, use default: not on:"
      end
    end

    test "turning one off leaves the other alone" do
      Flag.set!(:fire_engine, false, by: "UME")

      assert Flag.off?(:fire_engine)
      assert Flag.on?(:analytics)
      assert_equal %w[analytics], Flag.showing
    end

    test "turning it back on clears the override" do
      Flag.set!(:fire_engine, false, by: "UME")
      Flag.set!(:fire_engine, true, by: "UME")

      assert Flag.on?(:fire_engine)
      assert_equal 1, Flag.where(key: "fire_engine").count, "one row, flipped, not two"
    end

    test "a flip records who did it and when" do
      row = Flag.set!(:analytics, false, by: "UBOSS")

      assert_equal "UBOSS", row.changed_by
      assert_not_nil row.changed_at
    end

    test "a key the file does not know is refused, not quietly false" do
      assert_raises(Flag::Unknown) { Flag.on?(:teleporter) }
      assert_raises(Flag::Unknown) { Flag.set!(:teleporter, true, by: "UME") }
    end

    test "every flag says what it is and what it covers" do
      Flag::KEYS.each do |key|
        assert Flag.label(key).present?
        assert Flag.covers(key).present?
      end
    end

    test "the answer is remembered within a request and forgotten on a flip" do
      assert Flag.on?(:fire_engine)
      Flag.insert!({ key: "fire_engine", is_on: false, changed_by: "UME",
                     changed_at: Time.current })

      assert Flag.on?(:fire_engine), "the row landed behind the cache"

      Current.forget_flags
      assert Flag.off?(:fire_engine)
    end
  end
end
