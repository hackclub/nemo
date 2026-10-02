module Api
  class Approval < ApplicationRecord
    self.table_name = "api.approval"
    self.primary_key = "app_id"

    belongs_to :app, class_name: "Api::App", foreign_key: :app_id, inverse_of: :approval

    scope :live, -> { where(revoked_at: nil) }

    def self.held?(app_id)
      live.exists?(app_id: app_id)
    end

    def self.grant!(app_id, by:)
      row = find_or_initialize_by(app_id: app_id)
      row.update!(granted_by: by, granted_at: Time.current, revoked_by: nil, revoked_at: nil)
      row
    end

    def self.revoke!(app_id, by:)
      row = live.find_by(app_id: app_id)
      return nil if row.nil?

      row.update!(revoked_by: by, revoked_at: Time.current)
      row
    end
  end
end
