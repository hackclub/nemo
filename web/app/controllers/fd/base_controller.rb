module Fd
  class BaseController < ApplicationController
    before_action :require_fd
    before_action :needs_the_engine
    before_action :require_a_declaration, unless: :read_only_request?

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
        gates.any? do |one|
          next false if one[:only] && !one[:only].include?(action.to_s)
          next false if one[:except] && one[:except].include?(action.to_s)

          true
        end
      end
    end

    private

    def require_fd
      return if Fd::Access.manager?(current_staff)
      return if Authz.holds?(current_staff, "case.read")
      return head :forbidden if request.format.json?

      redirect_to root_path, alert: "Fire Engine is for the conduct team"
    end

    def needs_the_engine
      needs(:fire_engine)
    end

    def read_only_request?
      request.get? || request.head?
    end

    def require_a_declaration
      return if self.class.gated?(action_name)

      raise "#{self.class}##{action_name} writes without declaring a permission"
    end

    MISSING = :the_record_this_gate_needs_is_gone

    def gate(key, on)
      record = subject_for(on)
      return refuse!(key, nil) if record == MISSING
      return if current_staff&.may?(key, record)

      refuse!(key, record)
    end

    def subject_for(on)
      return nil if on.nil?

      on.respond_to?(:call) ? instance_exec(&on) : send(on)
    rescue ActiveRecord::RecordNotFound
      MISSING
    end

    CARRIES = 900

    def wrong!(field, said, was = nil)
      kept = was.to_s.length <= CARRIES ? was : nil
      flash[:wrong] = { "field" => field.to_s, "said" => said, "was" => kept }
      said
    end

    def refuse!(key, record = nil)
      log_refusal(key, record)
      flash[:tone] = "bad"
      flash[:said] = "Nothing was changed. #{Permission.label(key)} is #{least_for(key)} only."
      redirect_back fallback_location: fd_cases_path, alert: refusal_for(key, record)
    end

    def least_for(key)
      Permission::ROLE_LABELS.fetch(Permission.least(key)).downcase
    end

    def refusal_for(key, record)
      Access.why_not(current_staff, key, record)
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

      Access.not_yours(kase)
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
