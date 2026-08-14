module Fd
  class RolePermissionsController < BaseController
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

      redirect_to fd_settings_path(tab: "roles"), notice: moved_note(role, key, allowed)
    rescue RolePermission::NotAllowed => e
      redirect_to fd_settings_path(tab: "roles"), alert: e.message
    end

    private

    def moved_note(role, key, allowed)
      said = Permission::ROLE_LABELS.fetch(role, role).downcase
      allowed ? "#{said}s can now #{Permission.label(key).downcase}" : "#{key} is no longer theirs"
    end
  end
end
