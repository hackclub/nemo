module Fd
  class FireController < BaseController
    permit "case.read"
    WINDOW = 30.days

    def show
      @open = Case.unresolved.not_duplicate.count
      @unclaimed = Case.unresolved.not_duplicate.unassigned.count
      @resolve_lag = median_resolve_lag

      acted = Action.where(performed_at: WINDOW.ago..)
      @actions_total = acted.count
      @reversed = acted.reversed.count

      @endings = Case.ending_tally
      @closed_count = Case.where.not(resolved_at: nil).count
    end

    private

    def median_resolve_lag
      lags = Case.not_duplicate
        .where.not(resolved_at: nil)
        .where(opened_at: WINDOW.ago..)
        .pluck(Arel.sql("extract(epoch from (resolved_at - opened_at))"))
        .compact
        .sort
      return nil if lags.empty?

      lags[lags.size / 2]
    end
  end
end
