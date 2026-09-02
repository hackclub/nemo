module Fd
  class RolePermissionsController < BaseController
    skip_before_action :needs_the_engine
    permit "access.grant"

    def update
      role = params[:role].to_s
      key = params[:key].to_s
      allowed = params[:allowed] == "1"

      writing do
        row = RolePermission.set!(role, key, allowed, by: current_staff.user_id)
        audit(row, allowed ? "granted" : "revoked",
          after: { "permission" => key, "role" => role, "allowed" => allowed })
      end

      redirect_to admin_roles_path, notice: moved_note(role, key, allowed)
    rescue RolePermission::NotAllowed => e
      redirect_to admin_roles_path, alert: e.message
    end

    def destroy
      rows = RolePermission.all.to_a
      return redirect_to(admin_roles_path, alert: "nothing is off default") if rows.empty?

      writing do
        rows.each { |row| audit(row, back_to_default(row) ? "granted" : "revoked", **reset(row)) }
        RolePermission.where(id: rows.map(&:id)).delete_all
        Current.forget_roles
      end

      redirect_to admin_roles_path, notice: "#{rows.size} permission(s) put back to default"
    end

    private

    def back_to_default(row)
      Permission.default_roles(row.permission_key).include?(row.role)
    end

    def reset(row)
      held = back_to_default(row)
      {
        before: { "permission" => row.permission_key, "role" => row.role,
                  "allowed" => row.allowed },
        after: { "permission" => row.permission_key, "role" => row.role,
                 "allowed" => held, "why" => "put back to default" }
      }
    end

    def moved_note(role, key, allowed)
      said = Permission::ROLE_LABELS.fetch(role, role).downcase
      allowed ? "#{said}s can now #{Permission.label(key).downcase}" : "#{key} is no longer theirs"
    end
  end
end
