module Fd
  class FireController < BaseController
    WINDOW = 30.days
    READS_SHOWN = 6

    def show
      @open = Case.unresolved.not_duplicate.count
      @unclaimed = Case.unresolved.not_duplicate.unassigned.count
      @claim_lag = median_claim_lag

      acted = Action.where(performed_at: WINDOW.ago..)
      @actions_total = acted.count
      @reversed = acted.reversed.count

      @endings = Case.ending_tally
      @closed_count = Case.where.not(resolved_at: nil).count

      @reads = AccessLog.where(field_class: "identity", looked_at: WINDOW.ago..)
        .order(looked_at: :desc).limit(READS_SHOWN).to_a
      @reads_total = AccessLog.where(field_class: "identity", looked_at: WINDOW.ago..).count

      @names = Names.for(named)
    end

    private

    def median_claim_lag
      lags = CaseAssignee
        .joins("JOIN fd.cases ON fd.cases.id = fd.case_assignees.case_id")
        .where("fd.cases.opened_at > ?", WINDOW.ago)
        .pluck(Arel.sql("extract(epoch from (assigned_at - fd.cases.opened_at))"))
        .compact
        .sort
      return nil if lags.empty?

      lags[lags.size / 2]
    end

    def named
      @reads.flat_map { |row| [row.actor_id, row.subject_user_id] }.uniq
    end
  end
end
