require "test_helper"

class Channels::CrowdTest < ActiveSupport::TestCase
  def snapshot(members:, spoke:, viewed:)
    Analytics::MartChannelRange.new(total_members: members, members_who_posted: spoke,
      members_who_viewed: viewed)
  end

  def crowd = Channels::Crowd.new("C1")

  test "membership splits into speaking, reading and never opening it" do
    parts = crowd.composition(snapshot(members: 1000, spoke: 100, viewed: 400))

    assert_equal %w[spoke read never], parts.map(&:key)
    assert_equal [100, 300, 600], parts.map(&:people)
    assert_equal [10.0, 30.0, 60.0], parts.map(&:share)
  end

  test "more viewers than members never pushes a group below zero" do
    parts = crowd.composition(snapshot(members: 100, spoke: 90, viewed: 400))

    assert_equal [90, 10, 0], parts.map(&:people)
    assert parts.none? { |part| part.people.negative? }
  end

  test "fewer viewers than posters is treated as at least the posters" do
    parts = crowd.composition(snapshot(members: 100, spoke: 40, viewed: 10))

    assert_equal [40, 0, 60], parts.map(&:people)
  end

  test "no snapshot and no members leave nothing to draw" do
    assert_empty crowd.composition(nil)
    assert_empty crowd.composition(snapshot(members: 0, spoke: 0, viewed: 0))
  end

  test "every tenure band carries a label" do
    assert_equal Channels::Crowd::TENURE.keys.sort, Channels::Crowd::TENURE_ORDER.sort
    assert Channels::Crowd::TENURE.values.all?(&:present?)
  end
end
