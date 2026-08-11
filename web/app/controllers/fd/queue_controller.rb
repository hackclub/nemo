module Fd
  class QueueController < BaseController
    def index
      @cases = Case.unresolved.oldest_first.to_a
      @context = MemberContext.for(@cases.map(&:subject_user_id))
    end
  end
end
