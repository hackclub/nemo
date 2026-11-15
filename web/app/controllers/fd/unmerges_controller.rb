module Fd
  class UnmergesController < BaseController
    include UnmergesCases

    permit "case.resolve", on: -> { Case.find(params[:case_id]) }

    def create
      @case = Case.find(params[:case_id])
      return redirect_back_to_case(alert: "Case #{@case.id} is not merged") unless @case.duplicate?

      into = Case.find_by(id: @case.duplicate_of)
      return deny!("case.resolve", into) if into && !current_account.may?("case.resolve", into)

      unmerged = writing { unmerge(@case) }
      return redirect_back_to_case(alert: "Case #{@case.id} is not merged") if unmerged.nil?

      redirect_back_to_case(notice: "Case #{@case.id} unmerged from case #{unmerged.into_case_id}")
    end

    private

    def redirect_back_to_case(**flash)
      back = params[:back].to_i
      redirect_to fd_case_path(back.positive? ? back : @case), **flash
    end
  end
end
