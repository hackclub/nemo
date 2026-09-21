class CachetProfile < ApplicationRecord
  self.table_name = "app.cachet_profiles"
  self.primary_key = "user_id"

  def readonly?
    persisted?
  end
end
