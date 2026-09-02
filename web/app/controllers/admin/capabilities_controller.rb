module Admin
  class CapabilitiesController < BaseController
    def update
      return refuse unless may_grant?

      key = params[:key].to_s
      return refuse("#{key} is not a capability") unless Authz.keys.include?(key)
      return refuse("#{Authz.label(key)} cannot be handed out") if Authz.locked?(key)

      settle(key, params[:effect].to_s)
      redirect_to admin_person_path(who), notice: said(key, params[:effect].to_s)
    rescue Authz::Grant::NotAllowed => e
      refuse(e.message)
    end

    def destroy
      return refuse unless may_grant?

      key = params[:key].to_s
      Authz::Grant.live.for_person(who).capabilities.where(name: key)
        .find_each { |held| held.take_back!(by: current_account.user_id) }
      Current.forget_roles
      redirect_to admin_person_path(who), notice: "#{Authz.label(key)} is back to the role default"
    end

    private

    def who
      params[:person_user_id].to_s.upcase
    end

    def settle(key, effect)
      Authz::Grant.give!(who, kind: "capability", name: key, effect: effect,
        by: current_account.user_id, reason: params[:reason].presence)
      audit_change(key, effect)
      Current.forget_roles
    end

    def audit_change(key, effect)
      row = Authz::Grant.live.for_person(who).capabilities.find_by(name: key)
      return if row.nil?

      Fd::Audit.record(row, effect == "deny" ? "revoked" : "granted",
        actor: current_account.user_id, request_id: request.request_id,
        after: { "user_id" => who, "capability" => key, "effect" => effect })
    end

    def said(key, effect)
      effect == "deny" ? "#{Authz.label(key)} taken off them" : "#{Authz.label(key)} given to them"
    end

    def refuse(why = nil)
      redirect_to admin_person_path(who),
        alert: why || Community::Access.why_not(current_account, "analytics.grant")
    end
  end
end
