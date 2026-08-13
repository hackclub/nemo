module Fd
  class BaseController < ApplicationController
    before_action :require_write, unless: :read_only_request?

    private

    def read_only_request?
      request.get? || request.head?
    end

    def may_write?
      current_staff&.community_manager? || false
    end

    def require_write
      return if may_write?

      redirect_to fd_cases_path, alert: "you cannot make that change"
    end

    def writing
      ActiveRecord::Base.transaction { yield }
    end

    def not_yours(kase)
      return nil if kase.mine_or_free?(current_staff.user_id)

      "case #{kase.id} is assigned to #{kase.assignee_handles}, not to you"
    end

    def audit(record, verb, **options)
      Fd::Audit.record(
        record, verb,
        actor: current_staff.user_id,
        request_id: request.request_id,
        **options
      )
    end
  end
end
