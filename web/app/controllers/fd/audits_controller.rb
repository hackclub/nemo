module Fd
  class AuditsController < BaseController
    permit "access.read"

    WINDOW = 30.days
    PER_PAGE = 100
    CEILING = 2_000

    def show
      all = Deeds.new(nil, since: WINDOW.ago, limit: CEILING).rows
      @total = all.size
      @pages = [(@total / PER_PAGE.to_f).ceil, 1].max
      @page = [params[:page].to_i, 1].max.clamp(1, @pages)
      @rows = all.slice((@page - 1) * PER_PAGE, PER_PAGE) || []
      @actors = all.filter_map(&:actor).tally
      @names = Names.for(@rows.flat_map { |row| [row.actor, row.who, row.id] }.compact)
    end
  end
end
