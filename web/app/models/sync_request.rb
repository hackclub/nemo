class SyncRequest < ApplicationRecord
  self.table_name = "sync_request"

  CHANNEL = "sync_request".freeze
  CANCEL_CHANNEL = "sync_cancel".freeze
  KINDS = %w[full stage].freeze
  ACTIVE = %w[queued claimed].freeze

  STAGES = %w[
    team_stats top_posters member_days channel_days member_range channel_range
    admin_users_list users_list autojoin channel_names dbt
  ].freeze

  scope :active, -> { where(status: ACTIVE) }
  scope :recent_first, -> { order(id: :desc) }

  validates :kind, inclusion: { in: KINDS }
  validates :requested_by, presence: true
  validates :stage, presence: true, inclusion: { in: STAGES }, if: -> { kind == "stage" }
  validates :stage, absence: true, if: -> { kind == "full" }

  def self.queue!(kind:, requested_by:, stage: nil)
    transaction do
      request = create!(kind: kind, requested_by: requested_by, stage: stage)
      connection.execute("NOTIFY #{CHANNEL}")
      request
    end
  end

  def active?
    ACTIVE.include?(status)
  end

  def cancel!
    return false unless active?

    transaction do
      still_queued = self.class.where(id: id, status: "queued")
        .update_all(status: "cancelled", finished_at: Time.current, updated_at: Time.current)

      if still_queued.zero?
        update!(status: "cancelling")
        sql = self.class.sanitize_sql_array(["select pg_notify(?, ?)", CANCEL_CHANNEL, id.to_s])
        self.class.connection.execute(sql)
      else
        reload
      end
    end
    true
  end
end
