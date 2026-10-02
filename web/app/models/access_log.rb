class AccessLog < ApplicationRecord
  self.table_name = "access_log"

  def self.record!(actor:, subject_user_id:, field_class: "profile")
    create!(
      actor_id: actor.user_id,
      subject_user_id: subject_user_id,
      field_class: field_class,
      looked_at: Time.current
    )
  end

  def self.record_many!(actor:, subject_user_ids:, field_class: "profile")
    wanted = Array(subject_user_ids).compact.uniq
    return 0 if wanted.empty?

    now = Time.current
    insert_all!(wanted.map { |user_id|
      { actor_id: actor.user_id, subject_user_id: user_id, field_class: field_class,
        looked_at: now, created_at: now, updated_at: now }
    })
    wanted.size
  end
end
