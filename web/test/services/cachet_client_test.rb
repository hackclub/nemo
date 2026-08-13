require "test_helper"

class CachetClientTest < ActiveSupport::TestCase
  setup do
    @store = ActiveSupport::Cache::MemoryStore.new
    @was = Rails.cache
    Rails.instance_variable_set(:@cache, @store)
    @asked = []
  end

  teardown do
    Rails.instance_variable_set(:@cache, @was)
  end

  def answering(replies)
    original = CachetClient.method(:fetch)
    CachetClient.define_singleton_method(:fetch) do |user_id|
      TestState.asked << user_id
      replies[user_id]
    end
    yield
  ensure
    CachetClient.define_singleton_method(:fetch, original)
  end

  module TestState
    def self.asked = @asked ||= []
    def self.reset = @asked = []
  end

  def profile(name)
    CachetClient::Profile.new(display_name: name, image_url: nil, pronouns: nil)
  end

  test "a page of ids is asked for once each, not once per appearance" do
    TestState.reset
    answering("U1" => profile("Ada"), "U2" => profile("Bo")) do
      found = CachetClient.profiles(%w[U1 U2 U1 U2 U1])

      assert_equal %w[U1 U2], TestState.asked.sort
      assert_equal "Ada", found["U1"].display_name
      assert_equal "Bo", found["U2"].display_name
    end
  end

  test "a second page asks for nothing it already holds" do
    TestState.reset
    answering("U1" => profile("Ada")) do
      CachetClient.profiles(["U1"])
      CachetClient.profiles(["U1"])

      assert_equal ["U1"], TestState.asked
    end
  end

  test "a member cachet has not warmed yet is retried on the next page" do
    TestState.reset
    answering("U1" => CachetClient::PENDING) do
      CachetClient.profiles(["U1"])
    end

    assert_empty CachetClient.profiles([]), "no ids, no work"

    TestState.reset
    answering("U1" => profile("Ada")) do
      travel PENDING_GAP do
        found = CachetClient.profiles(["U1"])
        assert_equal ["U1"], TestState.asked, "the pending answer must not stick for twelve hours"
        assert_equal "Ada", found["U1"].display_name
      end
    end
  end

  PENDING_GAP = CachetClient::PENDING_TTL + 1.second

  test "a member who does not exist is not asked for again" do
    TestState.reset
    answering("U1" => nil) do
      assert_empty CachetClient.profiles(["U1"])
      CachetClient.profiles(["U1"])

      assert_equal ["U1"], TestState.asked, "a definite absence is worth remembering"
    end
  end

  test "one unknown member does not hide the rest of the page" do
    TestState.reset
    answering("U1" => profile("Ada"), "U2" => nil, "U3" => profile("Cy")) do
      found = CachetClient.profiles(%w[U1 U2 U3])

      assert_equal %w[U1 U3], found.keys.sort
      assert_nil found["U2"]
    end
  end

  test "profile is the single-id door onto the same batch" do
    TestState.reset
    answering("U1" => profile("Ada")) do
      assert_equal "Ada", CachetClient.profile("U1").display_name
    end
  end

  test "nils and repeats in the id list are dropped before anything is asked" do
    TestState.reset
    answering({}) do
      assert_empty CachetClient.profiles([nil, nil])
      assert_empty TestState.asked
    end
  end
end
