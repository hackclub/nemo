module Engine
  class Archive
    WORKER = "archive_worker".freeze
    ERRORS_SHOWN = 8
    ERROR_WIDTH = 90
    WORST_SHOWN = 12
    WORST_FLOOR = 500

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

    Report = Struct.new(:stages, :walked, :unreachable, :errors, :worst, :beat, keyword_init: true)

    def self.report
      totals = coverage
      Report.new(stages: stages(totals), walked: totals[:messages_held],
                 unreachable: totals[:unreachable], errors: errors, worst: worst, beat: beat)
    end

    def self.coverage
      row = Analytics::MartArchiveChannelCoverage.pick(
        Arel.sql("count(*)"),
        Arel.sql("count(*) filter (where unreachable_reason is not null)"),
        Arel.sql("count(*) filter (where history_complete)"),
        Arel.sql("coalesce(sum(messages_held), 0)"),
        Arel.sql("coalesce(sum(threads_known), 0)"),
        Arel.sql("coalesce(sum(threads_fetched), 0)"),
        Arel.sql("coalesce(sum(replies_held), 0)"),
        Arel.sql("coalesce(sum(replies_declared), 0)"),
        Arel.sql("max(last_walked_at)")
      )
      { channels: row[0].to_i, unreachable: row[1].to_i, complete: row[2].to_i,
        messages_held: row[3].to_i, threads_known: row[4].to_i, threads_fetched: row[5].to_i,
        replies_held: row[6].to_i, replies_declared: row[7].to_i, last_walk: row[8] }
    end

    def self.stages(totals)
      [
        Stage.new(name: "channels walked", done: totals[:complete],
                  total: totals[:channels] - totals[:unreachable], at: totals[:last_walk]),
        Stage.new(name: "threads fetched", done: totals[:threads_fetched],
                  total: totals[:threads_known], at: nil),
        Stage.new(name: "replies held", done: totals[:replies_held],
                  total: totals[:replies_declared], at: nil)
      ]
    end

    def self.worst
      Analytics::MartArchiveChannelCoverage
        .reachable
        .where("slack_messages >= ?", WORST_FLOOR)
        .where("held_share is not null")
        .order(held_share: :asc, slack_messages: :desc)
        .limit(WORST_SHOWN)
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
