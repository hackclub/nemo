require "test_helper"

class Fd::NamesTest < ActiveSupport::TestCase
  def profile(name)
    CachetClient::Profile.new(display_name: name, image_url: nil, pronouns: nil)
  end

  def seeded = Fd::Member.order(:user_id).first

  test "a member we hold reads as their name, with no call to cachet" do
    names = Fd::Names.for([seeded.user_id])
    assert_equal seeded.name, names[seeded.user_id]
    assert names.known?(seeded.user_id)
  end

  test "somebody we do not hold falls through to cachet" do
    names = Fd::Names.new(profiles: { "U1" => profile("Ada Lovelace") })
    assert_equal "Ada Lovelace", names["U1"]
  end

  test "cachet wins over the warehouse, since it is what the member calls themselves today" do
    names = Fd::Names.new(
      members: { "U1" => Fd::Member.new(user_id: "U1", display_name: "From the warehouse") },
      profiles: { "U1" => profile("From cachet") }
    )
    assert_equal "From cachet", names["U1"]
  end

  test "the warehouse still answers when cachet has nothing" do
    names = Fd::Names.new(
      members: { "U1" => Fd::Member.new(user_id: "U1", display_name: "From the warehouse") },
      profiles: { "U1" => nil }
    )
    assert_equal "From the warehouse", names["U1"]
  end

  test "a member with no display name falls back to their handle" do
    names = Fd::Names.new(
      members: { "U1" => Fd::Member.new(user_id: "U1", display_name: "", handle: "ada") }
    )
    assert_equal "ada", names["U1"]
  end

  test "somebody nobody has heard of falls back to the handle rather than going blank" do
    assert_equal "@U1", Fd::Names.none["U1"]
    assert_equal "@U1", Fd::Names.new(profiles: { "U1" => profile("") })["U1"]
  end

  test "no id at all reads as n/a" do
    assert_equal "n/a", Fd::Names.none[nil]
    assert_equal "n/a", Fd::Names.none[""]
  end

  test "a list reads as a sentence, mixing known and unknown" do
    names = Fd::Names.new(profiles: { "U1" => profile("Ada") })
    assert_equal "Ada and @U2", names.list(%w[U1 U2])
    assert_equal "Ada", names.list(["U1"])
    assert_equal "", names.list([])
  end

  test "a page of seeded members costs two queries, not one per member" do
    ids = Fd::Member.order(:user_id).limit(20).pluck(:user_id)
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      Fd::Names.for(ids)
    end

    assert_equal 2, queries, "the members, then the profiles we already hold"
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

  test "somebody nobody preloaded reads as their id, without reaching for the network" do
    answering({ "ULATE" => profile("Grace") }) do |calls|
      names = Fd::Names.new

      assert_equal "@ULATE", names["ULATE"]
      assert_empty calls, "rendering must never call cachet, it blocks the request"
    end
  end

  test "no number of unknown names makes a single call while rendering" do
    answering({}) do |calls|
      names = Fd::Names.new
      20.times { |i| names["UNONE#{i}"] }

      assert_empty calls
    end
  end

  test "a profile already fetched once is read back from the table, not the network" do
    CachetProfile.remember("UKEPT", profile("Grace"))

    answering({}) do |calls|
      assert_equal "Grace", Fd::Names.for(["UKEPT"])["UKEPT"]
      assert_empty calls, "a remembered profile costs one query, never a fetch"
    end
  end
end
