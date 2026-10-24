module Fd
  class CaseChat < ApplicationRecord
    self.table_name = "fd.case_chat"

    MAX_LENGTH = 4_000
    TAIL_LIMIT = 50

    LINE_THREAD = <<~SQL.squish.freeze
      CASE WHEN case_chat.ts IS NOT NULL THEN case_chat.thread_ts ELSE coalesce(
        (SELECT r.forwarded_ts FROM fd.case_reports r
          WHERE r.case_id = case_chat.case_id AND r.forwarded_ts IS NOT NULL ORDER BY r.id LIMIT 1),
        (SELECT coalesce(k.card_thread_ts, k.card_ts) FROM fd.cases k WHERE k.id = case_chat.case_id)
      ) END
    SQL

    scope :oldest_first, -> { order(:posted_at, :id) }
    scope :newest_first, -> { order(posted_at: :desc, id: :desc) }
    scope :outside_threads, lambda { |thread_ts|
      thread_ts.blank? ? all : where("coalesce(#{LINE_THREAD}, '') NOT IN (?)", thread_ts)
    }

    def self.tail(case_id, limit: TAIL_LIMIT, hidden_threads: [])
      where(case_id: case_id).outside_threads(hidden_threads).newest_first.limit(limit).to_a.reverse
    end

    def self.earlier_than(case_id, visible_count, hidden_threads: [])
      [where(case_id: case_id).outside_threads(hidden_threads).count - visible_count, 0].max
    end

    def self.before(case_id, line, hidden_threads: [])
      return [] if line.nil?

      where(case_id: case_id).outside_threads(hidden_threads)
        .where("(posted_at, id) < (?, ?)", line.posted_at, line.id).oldest_first.to_a
    end

    def self.roots_for(cases)
      rooted = cases.select { |kase| kase.card_channel_id.present? && kase.card_thread_ts.present? }
      return {} if rooted.empty?

      lines = where(channel_id: rooted.map(&:card_channel_id).uniq, ts: rooted.map(&:card_thread_ts).uniq)
        .index_by { |line| [line.channel_id, line.ts] }
      rooted.each_with_object({}) do |kase, roots|
        line = lines[[kase.card_channel_id, kase.card_thread_ts]]
        roots[kase.id] = line if line
      end
    end

    def self.root_for(kase, family_ids = kase.family_ids)
      roots = roots_for(Case.where(id: family_ids).to_a)
      roots[kase.id] || roots.values.min_by(&:posted_at)
    end

    def deleted?
      deleted_at.present?
    end

    def edited?
      edited_at.present?
    end

    def from_slack?
      ts.present?
    end
  end
end
