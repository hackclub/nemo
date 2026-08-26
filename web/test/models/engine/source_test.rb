require "test_helper"

module Engine
  class SourceTest < ActiveSupport::TestCase
    test "every source declares the six things a source has to say" do
      Source.all.each do |source|
        Source::DECLARED.each do |field|
          assert source.public_send(field).present?, "#{source.key} declares no #{field}"
        end
      end
    end

    test "declared values come from the allowed sets" do
      Source.all.each do |source|
        assert_includes Source::CADENCES, source.cadence, source.key
        assert_includes Source::GUARDS, source.guard, source.key
        assert_includes Source::RESUMES, source.resume, source.key
        assert_includes Source::RETENTIONS, source.retention, source.key
      end
    end

    test "nothing is pruned unless somebody asks for a window" do
      Source.all.each do |source|
        assert_not_equal "prune", source.retention, source.key
      end
    end

    test "the stages a person can trigger are the sources themselves" do
      assert_equal Source::KEYS, SyncRequest::STAGES
      assert_includes SyncRequest::STAGES, "member_channels", "the newest stages are triggerable"
      assert_includes SyncRequest::STAGES, "channel_membership"
    end

    test "a stage the file does not know is refused" do
      request = SyncRequest.new(kind: "stage", stage: "teleporter", requested_by: "UME")

      assert_not request.valid?
      assert_includes request.errors[:stage], "is not included in the list"
    end

    test "an unknown source raises rather than answering nil" do
      assert_raises(Source::Unknown) { Source["teleporter"] }
      assert_raises(Source::Unknown) { Source["team_stats"].limit(:batch) }
    end

    test "a source reports whether it is guarded and whether it can resume" do
      assert Source["member_range"].guarded?
      assert_not Source["team_stats"].guarded?
      assert Source["users_list"].resumable?
      assert_not Source["team_stats"].resumable?
    end
  end
end
