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
      walk = walked_totals
      threads = thread_totals
      Report.new(stages: stages(walk, threads), walked: walk[:messages],
                 unreachable: walk[:unreachable], errors: errors, worst: worst, beat: beat)
    end

    def self.walked_totals
      row = Analytics::FctChannelWalk.pick(
        Arel.sql("count(*) filter (where left(coalesce(last_error, ''), 7) = 'entity:')"),
        Arel.sql("count(*) filter (where history_complete)"),
        Arel.sql("coalesce(sum(messages_seen), 0)"),
        Arel.sql("max(last_walked_at)")
      )
      { channels: Analytics::DimChannel.count, unreachable: row[0].to_i, complete: row[1].to_i,
        messages: row[2].to_i, last_walk: row[3] }
    end

    def self.thread_totals
      row = Analytics::FctThread.pick(
        Arel.sql("count(*)"),
        Arel.sql("count(*) filter (where fetched_at is not null)"),
        Arel.sql("coalesce(sum(replies_fetched), 0)"),
        Arel.sql("coalesce(sum(reply_count), 0)")
      )
      { known: row[0].to_i, fetched: row[1].to_i,
        replies_held: row[2].to_i, replies_declared: row[3].to_i }
    end

    def self.stages(walk, threads)
      [
        Stage.new(name: "channels walked", done: walk[:complete],
                  total: walk[:channels] - walk[:unreachable], at: walk[:last_walk]),
        Stage.new(name: "threads fetched", done: threads[:fetched],
                  total: threads[:known], at: nil),
        Stage.new(name: "replies held", done: threads[:replies_held],
                  total: threads[:replies_declared], at: nil)
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
