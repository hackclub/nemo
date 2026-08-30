class CachetProfile < ApplicationRecord
  self.primary_key = "user_id"

  def self.remember(user_id, profile)
    upsert({ user_id: user_id, display_name: profile.display_name,
             image_url: profile.image_url, pronouns: profile.pronouns,
             fetched_at: Time.current }, unique_by: :user_id)
  rescue ActiveRecord::StatementInvalid
    nil
  end
end
