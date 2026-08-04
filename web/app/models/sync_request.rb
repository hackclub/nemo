class SyncRequest < ApplicationRecord
  self.table_name = "sync_request"

  CHANNEL = "sync_request".freeze
  KINDS = %w[full stage].freeze
  ACTIVE = %w[queued claimed].freeze

  scope :active, -> { where(status: ACTIVE) }
  scope :recent_first, -> { order(id: :desc) }

  validates :kind, inclusion: { in: KINDS }
  validates :requested_by, presence: true
  validates :stage, presence: true, if: -> { kind == "stage" }
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
end
