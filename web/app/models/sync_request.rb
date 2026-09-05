class SyncRequest < ApplicationRecord
  self.table_name = "sync_request"

  CHANNEL = "sync_request".freeze
  CANCEL_CHANNEL = "sync_cancel".freeze
  KINDS = %w[full stage].freeze
  ACTIVE = %w[queued claimed cancelling].freeze

  STAGES = Engine::Source::KEYS

  scope :active, -> { where(status: ACTIVE) }
  scope :recent_first, -> { order(id: :desc) }

  validates :kind, inclusion: { in: KINDS }
  validates :requested_by, presence: true
  validates :stage, presence: true, inclusion: { in: STAGES }, if: -> { kind == "stage" }
  validates :stage, absence: true, if: -> { kind == "full" }

  class AlreadyRunning < StandardError; end

  def self.queue!(kind:, requested_by:, stage: nil)
    transaction do
      request = create!(kind: kind, requested_by: requested_by, stage: stage)
      connection.execute("NOTIFY #{CHANNEL}")
      request
    end
  rescue ActiveRecord::RecordNotUnique
    raise AlreadyRunning, "a sync is already queued or running"
  end

  def active?
    ACTIVE.include?(status)
  end

  def cancel!(worker_gone: false)
    return false unless active?

    stopped = false
    transaction do
      still_queued = self.class.where(id: id, status: "queued")
        .update_all(status: "cancelled", finished_at: Time.current, updated_at: Time.current)

      if still_queued.positive?
        stopped = true
        reload
        next
      end

      claimed = self.class.where(id: id, status: "claimed")
      running = if worker_gone
        claimed.update_all(status: "cancelled", finished_at: Time.current, updated_at: Time.current)
      else
        claimed.update_all(status: "cancelling", updated_at: Time.current)
      end
      next if running.zero?

      stopped = true
      reload
      next if worker_gone

      sql = self.class.sanitize_sql_array(["select pg_notify(?, ?)", CANCEL_CHANNEL, id.to_s])
      self.class.connection.execute(sql)
    end
    stopped
  end
end
