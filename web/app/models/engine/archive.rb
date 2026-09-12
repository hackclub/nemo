module Engine
  class Archive
    WORKER = "archive_worker".freeze
    ERRORS_SHOWN = 10
    ERROR_WIDTH = 90
    WORST_SHOWN = 12
    WORST_FLOOR = 500
    WAITING_SHOWN = 12
    DAYS_SHOWN = 90
    QUEUES = %w[channel_tail channel_replies].freeze

    TOTALS_SQL = <<~SQL.freeze
      SELECT count(*)                                                        AS channels,
             count(*) FILTER (WHERE unreachable_reason IS NOT NULL)          AS unreachable,
             count(*) FILTER (WHERE unreachable_reason IS NULL)              AS reachable,
             count(*) FILTER (WHERE walked)                                  AS walked,
             count(*) FILTER (WHERE history_complete)                        AS complete,
             count(*) FILTER (WHERE unreachable_reason IS NULL AND NOT walked) AS untouched,
             count(*) FILTER (WHERE messages_held > 0)                       AS holding,
             coalesce(sum(messages_held), 0)                                 AS messages_held,
             coalesce(sum(parents_held), 0)                                  AS parents_held,
             coalesce(sum(replies_held), 0)                                  AS replies_held,
             coalesce(sum(threads_known), 0)                                 AS threads_known,
             coalesce(sum(threads_fetched), 0)                               AS threads_fetched,
             coalesce(sum(replies_declared), 0)                              AS replies_declared,
             coalesce(sum(slack_messages), 0)                                AS slack_messages,
             min(oldest_held)                                                AS oldest_held,
             max(newest_held)                                                AS newest_held,
             max(last_walked_at)                                             AS last_walked_at
      FROM   analytics.mart_archive_channel_coverage
    SQL

    Totals = Struct.new(:row) do
      %w[channels unreachable reachable walked complete untouched holding messages_held
         parents_held replies_held threads_known threads_fetched replies_declared
         slack_messages].each do |name|
        define_method(name) { row[name].to_i }
      end

      def oldest_held = row["oldest_held"]&.to_time
      def newest_held = row["newest_held"]&.to_time
      def last_walked_at = row["last_walked_at"]&.to_time

      def held_days
        return nil if oldest_held.nil? || newest_held.nil?

        (newest_held.to_date - oldest_held.to_date).to_i + 1
      end

      def threads_waiting = [threads_known - threads_fetched, 0].max

      def replies_waiting = [replies_declared - replies_held, 0].max
    end

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

    Report = Struct.new(:totals, :stages, :worst, :waiting, :errors, :beat, :days, :queues,
      keyword_init: true)

    def self.report
      totals = Totals.new(ApplicationRecord.connection.select_one(TOTALS_SQL))
      Report.new(totals: totals, stages: stages(totals), worst: worst, waiting: waiting,
        errors: errors, beat: beat, days: days, queues: queues)
    end

    def self.stages(totals)
      [
        Stage.new(name: "channels walked", done: totals.complete, total: totals.reachable,
                  at: totals.last_walked_at),
        Stage.new(name: "threads fetched", done: totals.threads_fetched,
                  total: totals.threads_known, at: nil),
        Stage.new(name: "replies held", done: totals.replies_held,
                  total: totals.replies_declared, at: nil),
        Stage.new(name: "messages held", done: totals.messages_held,
                  total: totals.slack_messages.positive? ? totals.slack_messages : nil, at: nil)
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

    def self.waiting
      Analytics::MartArchiveChannelCoverage
        .reachable
        .where("not history_complete")
        .order(Arel.sql("walked, threads_known - threads_fetched desc, messages_held desc"))
        .limit(WAITING_SHOWN)
    end

    def self.errors
      Analytics::FctChannelWalk.failed
        .group(Arel.sql("left(last_error, #{ERROR_WIDTH})"))
        .order(Arel.sql("count(*) desc"))
        .limit(ERRORS_SHOWN)
        .pluck(Arel.sql("left(last_error, #{ERROR_WIDTH})"), Arel.sql("count(*)"),
          Arel.sql("max(last_walked_at)"))
    end

    def self.beat
      Analytics::FctWorkerHeartbeat.find_by(worker: WORKER)
    end

    def self.days
      Analytics::MartArchiveDayCoverage.newest_first.limit(DAYS_SHOWN).to_a.reverse
    end

    def self.queues
      Analytics::FctWorkQueue.where(work_kind: QUEUES).order(:work_kind).to_a
    end
  end
end
