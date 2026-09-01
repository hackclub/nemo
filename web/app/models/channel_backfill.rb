class ChannelBackfill < ApplicationRecord
  self.table_name = "channel_backfill"

  CHANNEL = "channel_backfill".freeze
  STATES = %w[queued draining paused complete cancelled].freeze
  OPEN = %w[queued draining paused].freeze
  REQUESTS_PER_MESSAGE = 0.076

  scope :open_work, -> { where(state: OPEN) }
  scope :in_line, -> { where(state: "queued").order(:priority, :requested_at) }

  validates :state, inclusion: { in: STATES }
  validates :requested_by, presence: true

  def self.estimate(channel)
    counted = channel.try(:thread_parents)
    return counted if counted

    messages = observed_messages(channel)
    return nil unless messages&.positive?

    (messages * REQUESTS_PER_MESSAGE).round
  end

  def self.observed_messages(channel)
    daily = Analytics::MartChannelActivity
      .where(channel_id: channel.channel_id).sum(:messages_posted)
    return daily if daily.positive?

    channel.try(:range_messages) ||
      Analytics::MartChannelRange.where(channel_id: channel.channel_id).pick(:messages_posted)
  end

  def self.opt_in!(channel_id:, requested_by:, estimated_requests: nil, threads_expected: nil)
    row = find_or_initialize_by(channel_id: channel_id)
    row.assign_attributes(
      state: "queued", requested_by: requested_by, requested_at: Time.current,
      estimated_requests: estimated_requests, threads_expected: threads_expected,
      cancelled_by: nil, finished_at: nil, last_error: nil
    )
    row.save!
    wake!
    row
  end

  STALE_CLAIM = 30.minutes

  def self.wake!
    live = SyncRequest.active
      .where("status = 'queued' OR claimed_at > ?", STALE_CLAIM.ago)
      .exists?
    return false if live

    SyncRequest.queue!(kind: "stage", stage: "channel_replies", requested_by: "channel_backfill")
    true
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    false
  end

  def opt_out!(by:)
    update!(state: "cancelled", cancelled_by: by, finished_at: Time.current)
  end

  def open? = OPEN.include?(state)

  def progress
    return nil if threads_expected.to_i.zero?

    (threads_fetched.to_f / threads_expected).clamp(0.0, 1.0)
  end

  def place_in_line
    return nil unless state == "queued"

    self.class.in_line.where("priority < :p OR (priority = :p AND requested_at < :t)",
      p: priority, t: requested_at).count + 1
  end
end
