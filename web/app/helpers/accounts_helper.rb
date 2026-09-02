module AccountsHelper
  def you_may(role)
    return {} if role.blank?

    if Community::Permission.family_of(role)
      Community::Permission.held_by(role).to_h { |key| [key, Community::Permission.label(key)] }
    else
      Fd::Permission.held_by(role).to_h { |key| [key, Fd::Permission.label(key)] }
    end
  end
end
