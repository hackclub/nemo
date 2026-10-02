class Authz
  class Override < ApplicationRecord
    self.table_name = "app.role_override"

    def self.moved?(key)
      where(capability: key.to_s).exists?
    end

    def self.for_role(role)
      where(role: role.to_s).pluck(:capability, :allowed).to_h
    end
  end
end
