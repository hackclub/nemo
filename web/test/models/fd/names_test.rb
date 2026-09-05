require "test_helper"

class Fd::NamesTest < ActiveSupport::TestCase
  def seeded = Fd::Member.order(:user_id).first

  test "a member we hold reads as their name" do
    names = Fd::Names.for([seeded.user_id])
    assert_equal seeded.name, names[seeded.user_id]
    assert names.known?(seeded.user_id)
  end

  test "a member with no display name falls back to their handle" do
    names = Fd::Names.new(
      members: { "U1" => Fd::Member.new(user_id: "U1", display_name: "", handle: "ada") }
    )
    assert_equal "ada", names["U1"]
  end

  test "somebody nobody has heard of falls back to the handle rather than going blank" do
    assert_equal "@U1", Fd::Names.none["U1"]
    assert Fd::Names.none.unknown?("U1")
    assert_equal "@U1", Fd::Names.new(
      members: { "U1" => Fd::Member.new(user_id: "U1", display_name: "", handle: "") }
    )["U1"]
  end

  test "somebody with a name on file is not unknown" do
    names = Fd::Names.new(members: { "U1" => Fd::Member.new(user_id: "U1", display_name: "Ada") })
    assert_not names.unknown?("U1")
    assert_not Fd::Names.none.unknown?(nil)
  end

  test "no id at all reads as n/a" do
    assert_equal "n/a", Fd::Names.none[nil]
    assert_equal "n/a", Fd::Names.none[""]
  end

  test "an actor that is not a slack id reads as itself, and is never looked up" do
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }

    names = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      Fd::Names.for(%w[migration seed dev:people])
    end

    assert_equal 0, queries, "provenance strings are not members"
    assert_equal "migration", names["migration"]
    assert_equal "dev:people", names["dev:people"]
  end

  test "a list reads as a sentence, mixing known and unknown" do
    names = Fd::Names.new(members: { "U1" => Fd::Member.new(user_id: "U1", display_name: "Ada") })
    assert_equal "Ada and @U2", names.list(%w[U1 U2])
    assert_equal "Ada", names.list(["U1"])
    assert_equal "", names.list([])
  end

  test "a page of seeded members costs one query, not one per member" do
    ids = Fd::Member.order(:user_id).limit(20).pluck(:user_id)
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      Fd::Names.for(ids)
    end

    assert_equal 1, queries, "the members we hold, nothing else"
  end

  test "the member row itself is reachable, for pages that want more than a name" do
    names = Fd::Names.for([seeded.user_id])
    assert_equal seeded.user_id, names.member(seeded.user_id).user_id
    assert_nil names.member("UNOBODY")
  end

  def answering(found)
    was = CachetClient.method(:profiles)
    calls = []
    CachetClient.define_singleton_method(:profiles) do |ids|
      calls << ids
      found.slice(*ids)
    end
    yield calls
  ensure
    CachetClient.define_singleton_method(:profiles, was)
  end

end
