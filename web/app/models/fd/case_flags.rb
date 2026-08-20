module Fd
  class CaseFlags
    Flag = Struct.new(:tone, :headline, :detail, keyword_init: true)

    UNCLAIMED_AFTER = 5.days
    REPORT_WINDOW = 30.days
    REPORT_THRESHOLD = 3

    def self.for_case(kase, names: Names.none)
      new(names: names).for_case(kase)
    end

    def self.for_queue(names: Names.none)
      new(names: names).for_queue
    end

    def initialize(names: Names.none)
      @names = names
    end

    def for_case(kase)
      [priors_flag(kase), merge_flag(kase), unclaimed_flag(kase)].compact
    end

    def for_queue
      [unclaimed_flag(oldest_unclaimed), merge_flag_any].compact
    end

    private

    def oldest_unclaimed
      Case.unresolved.unassigned.where(opened_at: ..UNCLAIMED_AFTER.ago).order(:opened_at).first
    end

    def unclaimed_flag(kase)
      return nil if kase.nil? || kase.resolved? || kase.assigned?
      return nil unless kase.opened_at <= UNCLAIMED_AFTER.ago

      days = ((Time.current - kase.opened_at) / 1.day).floor
      Flag.new(tone: "crit",
        headline: "Case #{kase.id} has sat unclaimed for #{days} #{days == 1 ? 'day' : 'days'}.",
        detail: "Nothing logged on it.")
    end

    def priors_flag(kase)
      return nil unless kase.subject_user_ids.one?

      subject = kase.subject_user_ids.first
      count = Case.with_subject(subject)
        .where(opened_at: (kase.opened_at - REPORT_WINDOW)..kase.opened_at).count
      return nil if count < REPORT_THRESHOLD

      Flag.new(tone: "crit",
        headline: "#{count.ordinalize} report about #{@names[subject]} in 30 days.",
        detail: nil)
    end

    def merge_flag(kase)
      other_id = same_thread_case_id(kase)
      return nil if other_id.nil?

      Flag.new(tone: "mid", headline: "Case #{other_id} is about the same thread.",
        detail: "Worth merging.")
    end

    def merge_flag_any
      pair = same_thread_pair
      return nil if pair.nil?

      Flag.new(tone: "mid", headline: "#{pair[0]} and #{pair[1]} are about the same thread.",
        detail: "Worth merging.")
    end

    def same_thread_case_id(kase)
      kase.threads.each do |thread|
        other = CaseThread.joins(:kase)
          .merge(Case.unresolved.not_duplicate)
          .where(channel_id: thread.channel_id, thread_ts: thread.thread_ts)
          .where.not(case_id: kase.id)
          .first
        return other.case_id if other
      end
      nil
    end

    SAME_THREAD_PAIR_SQL = <<~SQL.squish.freeze
      SELECT ct1.case_id AS a, ct2.case_id AS b
      FROM fd.case_threads ct1
      JOIN fd.case_threads ct2
        ON ct1.channel_id = ct2.channel_id AND ct1.thread_ts = ct2.thread_ts
       AND ct1.case_id < ct2.case_id
      JOIN fd.cases ca ON ca.id = ct1.case_id AND ca.resolved_at IS NULL AND ca.duplicate_of IS NULL
      JOIN fd.cases cb ON cb.id = ct2.case_id AND cb.resolved_at IS NULL AND cb.duplicate_of IS NULL
      LIMIT 1
    SQL

    def same_thread_pair
      row = ActiveRecord::Base.connection.select_one(SAME_THREAD_PAIR_SQL)
      return nil if row.nil?

      [row["a"], row["b"]]
    end
  end
end
