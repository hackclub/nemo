module Fd
  class BaseController < ApplicationController
    before_action :require_a_declaration, unless: :read_only_request?

    class << self
      def permit(key, on: nil, **filters)
        declared << key
        before_action(**filters) { gate(key, on) }
      end

      def declared
        @declared ||= []
      end
    end

    private

    def read_only_request?
      request.get? || request.head?
    end

    def require_a_declaration
      return if self.class.declared.any?

      raise "#{self.class} writes without declaring a permission"
    end

    def gate(key, on)
      record = subject_for(on)
      return if current_staff&.may?(key, record)

      refuse!(key, record)
    end

    def subject_for(on)
      return nil if on.nil?

      on.respond_to?(:call) ? instance_exec(&on) : send(on)
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def refuse!(key, record = nil)
      log_refusal(key, record)
      redirect_back fallback_location: fd_cases_path, alert: refusal_for(key, record)
    end

    def refusal_for(key, record)
      return Permission.refusal(key) unless holds?(key)
      return not_yours(record) if record.respond_to?(:mine_or_free?)

      "that is not yours"
    end

    def holds?(key)
      current_staff&.role.present? && Permission.roles(key).include?(current_staff.role)
    end

    def log_refusal(key, record)
      AuditEntry.create!(
        actor_user_id: current_staff&.user_id,
        actor_kind: "human",
        entity_type: record ? Audit.entity_type(record) : "permission",
        entity_id: record.respond_to?(:id) ? record.id : 0,
        verb: "refused",
        after: { "permission" => key, "role" => current_staff&.role },
        source_app: Audit::SOURCE_APP,
        request_id: request.request_id
      )
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
