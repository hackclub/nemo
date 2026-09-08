module Engine
  class Archive
    WORKER = "archive_worker".freeze
    ERRORS_SHOWN = 8
    ERROR_WIDTH = 90

    Stage = Struct.new(:name, :done, :total, :at, keyword_init: true) do
      def outstanding
        return nil if total.nil?

        [total - done, 0].max
      end

      def share
        return nil if total.nil? || total.zero?

        done.to_f / total * 100
      end
    end

    Report = Struct.new(:stages, :walked, :errors, :beat, keyword_init: true)

    def self.report
      walked, complete, last_walk = walk
      Report.new(stages: stages(complete, last_walk), walked: walked,
                 errors: errors, beat: beat)
    end

    def self.walk
      row = Analytics::FctChannelWalk.pick(
        Arel.sql("coalesce(sum(messages_seen), 0)"),
        Arel.sql("count(*) filter (where history_complete)"),
        Arel.sql("max(last_walked_at)")
      )
      [row[0].to_i, row[1].to_i, row[2]]
    end

    def self.stages(complete, last_walk)
      threads, fetched, held, owed = replies
      [
        Stage.new(name: "channels walked", done: complete,
                  total: Analytics::DimChannel.count, at: last_walk),
        Stage.new(name: "threads fetched", done: fetched, total: threads, at: nil),
        Stage.new(name: "replies held", done: held, total: held + owed, at: nil)
      ]
    end

    def self.replies
      row = Analytics::FctThread.pick(
        Arel.sql("count(*)"),
        Arel.sql("count(*) filter (where fetched_at is not null)"),
        Arel.sql("coalesce(sum(replies_fetched), 0)"),
        Arel.sql("coalesce(sum(reply_count) filter (where fetched_at is null), 0)")
      )
      row.map(&:to_i)
    end

    def self.errors
      Analytics::FctChannelWalk.failed
        .group(Arel.sql("left(last_error, #{ERROR_WIDTH})"))
        .order(Arel.sql("count(*) desc"))
        .limit(ERRORS_SHOWN)
        .pluck(Arel.sql("left(last_error, #{ERROR_WIDTH})"), Arel.sql("count(*)"))
    end

    def self.beat
      Analytics::FctWorkerHeartbeat.find_by(worker: WORKER)
    end
  end
end
