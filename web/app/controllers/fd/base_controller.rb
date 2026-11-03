module Fd
  class BaseController < ApplicationController
    before_action :require_fd
    before_action :require_engine
    before_action :require_permission_declaration, unless: :read_only_request?
    around_action :in_viewer_zone

    class << self
      def permit(key, on: nil, **filters)
        declared << key
        gates << {
          only: Array(filters[:only]).map(&:to_s).presence,
          except: Array(filters[:except]).map(&:to_s).presence
        }
        before_action(**filters) { gate(key, on) }
      end

      def declared
        @declared ||= []
      end

      def gates
        @gates ||= []
      end

      def gated?(action)
        gates.any? do |filter|
          next false if filter[:only] && !filter[:only].include?(action.to_s)
          next false if filter[:except] && filter[:except].include?(action.to_s)

          true
        end
      end
    end

    private

    def require_fd
      return if Fd::Access.manager?(current_account)
      return if Authz.holds?(current_account, "case.read")
      return head :forbidden if request.format.json?

      redirect_to root_path, alert: "Fire Engine access required"
    end

    def require_engine
      require_flag(:fire_engine)
    end

    def record_audit_reads(query)
      query.identity_reads.each do |field_class, user_ids|
        AccessLog.record_many!(actor: current_account, subject_user_ids: user_ids, field_class: field_class)
      end
    end

    def in_viewer_zone(&)
      Time.use_zone(viewer_time_zone, &)
    end

    def viewer_time_zone
      tz = current_member&.tz
      ActiveSupport::TimeZone[tz.to_s] || ActiveSupport::TimeZone[viewer_zone] || Time.zone
    end

    def read_only_request?
      request.get? || request.head?
    end

    def require_permission_declaration
      return if self.class.gated?(action_name)

      raise "#{self.class}##{action_name} writes without declaring a permission"
    end

    MISSING_RECORD = :missing_record

    def gate(key, on)
      record = subject_for(on)
      return deny!(key, nil) if record == MISSING_RECORD
      return if current_account&.may?(key, record)

      deny!(key, record)
    end

    def subject_for(on)
      return nil if on.nil?

      on.respond_to?(:call) ? instance_exec(&on) : send(on)
    rescue ActiveRecord::RecordNotFound
      MISSING_RECORD
    end

    MAX_FIELD_VALUE_LENGTH = 900

    def field_error!(field, message, submitted_value = nil)
      stored_value = submitted_value.to_s.length <= MAX_FIELD_VALUE_LENGTH ? submitted_value : nil
      flash[:field_error] = { "field" => field.to_s, "message" => message, "was" => stored_value }
      message
    end

    def deny!(key, record = nil)
      log_refusal(key, record)
      flash[:tone] = "bad"
      flash[:detail] = Authz.refusal(key).upcase_first
      redirect_back fallback_location: fd_cases_path, alert: refusal_for(key, record)
    end

    def refusal_for(key, record)
      Access.why_not(current_account, key, record)
    end

    def log_refusal(key, record)
      AuditEntry.create!(
        actor_user_id: current_account&.user_id,
        actor_kind: "human",
        entity_type: record ? Audit.entity_type(record) : "permission",
        entity_id: record.respond_to?(:id) ? record.id : 0,
        verb: "refused",
        after: { "permission" => key, "roles" => Authz.effective_roles(current_account&.user_id) },
        source_app: Audit::SOURCE_APP,
        request_id: request.request_id
      )
    end

    def writing
      ActiveRecord::Base.transaction { yield }
    end

    def audit(record, verb, **options)
      Fd::Audit.record(
        record, verb,
        actor: current_account.user_id,
        request_id: request.request_id,
        **options
      )
    end
  end
end
