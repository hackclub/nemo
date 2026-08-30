module Fd
  class AuditsController < BaseController
    permit "access.read"

    WINDOW = 30.days
    PER_PAGE = 100

    def show
      counting = Deeds.new(nil, since: WINDOW.ago)
      @total = counting.total
      @pages = [(@total / PER_PAGE.to_f).ceil, 1].max
      @page = [params[:page].to_i, 1].max.clamp(1, @pages)

      @deeds = Deeds.new(nil, since: WINDOW.ago, limit: PER_PAGE,
        offset: (@page - 1) * PER_PAGE)
      @rows = @deeds.rows
      @names = Names.for(@deeds.member_ids)
    end
  end
end
