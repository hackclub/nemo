module Fd
  class RolePermissionsController < BaseController
    skip_before_action :needs_the_engine
    permit "access.grant"

    def update
      role = params[:role].to_s
      key = params[:key].to_s
      allowed = params[:allowed] == "1"

      writing do
        row = move!(role, key, allowed)
        audit(row, allowed ? "granted" : "revoked", entity_id: "#{role}/#{key}",
          after: { "permission" => key, "role" => role, "allowed" => allowed })
      end

      redirect_to admin_roles_path, notice: moved_note(role, key, allowed)
    rescue NotAllowed => e
      redirect_to admin_roles_path, alert: e.message
    end

    def destroy
      rows = Authz::Override.all.to_a
      return redirect_to(admin_roles_path, alert: "nothing is off default") if rows.empty?

      writing do
        rows.each do |row|
          audit(row, back_to_default?(row) ? "granted" : "revoked",
            entity_id: "#{row.role}/#{row.capability}", **reset(row))
        end
        Authz::Override.delete_all
        Current.forget_roles
      end

      redirect_to admin_roles_path, notice: "#{rows.size} capability(s) put back to default"
    end

    private

    class NotAllowed < StandardError; end

    def move!(role, key, allowed)
      check!(role, key, allowed)
      Authz::Override.upsert({ role: role, capability: key, allowed: allowed,
                               changed_by: current_staff.user_id, changed_at: Time.current },
        unique_by: %i[role capability])
      Current.forget_roles
      Authz::Override.find_by(role: role, capability: key)
    end

    def check!(role, key, _allowed)
      refuse "#{role} is not a role" unless Authz.role_names.include?(role)
      refuse "#{role} holds everything already" if Authz.superadmin?(role)
      refuse "#{key} is not a capability" unless Authz.keys.include?(key)
      refuse "#{key} cannot be moved" if Authz.locked?(key)
    end

    def back_to_default?(row)
      Authz.baseline(row.role).include?(row.capability)
    end

    def reset(row)
      {
        before: { "permission" => row.capability, "role" => row.role,
                  "allowed" => row.allowed },
        after: { "permission" => row.capability, "role" => row.role,
                 "allowed" => back_to_default?(row),
                 "why" => "put back to default" }
      }
    end

    def moved_note(role, key, allowed)
      said = Authz.role_label(role).downcase
      return "#{said}s can now #{Authz.label(key).downcase}" if allowed

      "#{key} is no longer theirs"
    end

    def refuse(why)
      raise NotAllowed, why
    end
  end
end
