module Admin
  class RolesController < BaseController
    FAMILIES = %w[fd read ops].freeze

    def show
      @family = FAMILIES.include?(params[:family]) ? params[:family] : "fd"
      @counts = { "fd" => Fd::Permission.keys.size }.merge(
        Community::Permission.families.index_with { |family|
          Community::Permission.keys.count { |key| Community::Permission.family(key) == family }
        }
      )
      @holders = holders
      @family == "fd" ? fd_matrix : community_matrix
    end

    private

    def fd_matrix
      @roles = Fd::Permission::ROLES
      @keys = Fd::Permission.by_area
      @moved = Fd::Permission.keys.count { |key| Fd::RolePermission.moved?(key) }
    end

    def community_matrix
      @roles = Community::Permission.roles(@family)
      @moved = 0
      @keys = Community::Permission.by_area.transform_values { |keys|
        keys.select { |key| Community::Permission.family(key) == @family }
      }.reject { |_area, keys| keys.empty? }
    end

    def holders
      fd = Fd::AccessGrant.live.group(:role).count
      community = Community::Grant.live.group(:role).count
      managers = Staff.where(community_manager: true).count
      Community::Permission.families.each do |family|
        top = Community::Permission.superadmin(family)
        community[top] = (community[top] || 0) + managers
      end
      fd.merge(community).merge(Fd::Access::MANAGER_ROLE => managers)
    end
  end
end
