module Admin
  class RolesController < BaseController
    def show
      @roles = Authz.grantable_roles.reject { |role| Authz.superadmin?(role) }
      @keys = Authz.by_area
      @holders = holders
      @overrides = Authz::Override.all.index_by { |row| [row.role, row.capability] }
      @moved = @overrides.size
    end

    private

    def holders
      rows = ApplicationRecord.connection.select_all(
        "SELECT role, count(*) AS held FROM app.effective_role GROUP BY role"
      )
      rows.to_h { |row| [row["role"], row["held"].to_i] }
    end
  end
end
