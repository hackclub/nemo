module AccountsHelper
  def you_may(role)
    return {} if role.blank?
    return fd_keys(Fd::Permission.keys) if role == Fd::Access::MANAGER_ROLE

    if Community::Permission.family_of(role)
      Community::Permission.held_by(role).to_h { |key| [key, Community::Permission.label(key)] }
    else
      fd_keys(Fd::Permission.held_by(role))
    end
  end

  def whole_family(role)
    family = Community::Permission.family_of(role)
    return Fd::Permission.keys.size if family.nil?

    Community::Permission.keys.count { |key| Community::Permission.family(key) == family }
  end

  private

  def fd_keys(keys)
    keys.to_h { |key| [key, Fd::Permission.label(key)] }
  end
end
