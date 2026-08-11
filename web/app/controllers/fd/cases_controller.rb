module Fd
  class CasesController < BaseController
    def show
      @case = Case.find(params[:id])
      @threads = @case.threads.primary_first.to_a
      @participants = @case.participants.by_role.to_a
      @reports = @case.reports.oldest_first.to_a
      @siblings = @case.sibling_cases.oldest_first.to_a
      @context = MemberContext.for(
        [@case.subject_user_id] +
          @participants.map(&:user_id) +
          @siblings.map(&:subject_user_id)
      )
    end
  end
end
