module Api
  class AccessRequest < ApplicationRecord
    self.table_name = "api.access_request"

    PENDING = "pending".freeze
    APPROVED = "approved".freeze
    DECLINED = "declined".freeze
    WITHDRAWN = "withdrawn".freeze

    MAX_REASON = 500
    SHORTEST_REASON = 10

    class AlreadyError < StandardError; end
    class TooThinError < StandardError; end

    belongs_to :app, class_name: "Api::App", foreign_key: :app_id, inverse_of: false

    scope :pending, -> { where(state: PENDING) }
    scope :settled, -> { where.not(state: PENDING) }

    def self.open_for?(app_id)
      pending.exists?(app_id: app_id)
    end

    def self.for_owner(user_id)
      where(app_id: App.where(owner_user_id: user_id).select(:id)).order(created_at: :desc)
    end

    def self.queue
      pending.where(app_id: App.live.select(:id)).order(created_at: :asc)
    end

    def self.ask!(app, reason:)
      raise AlreadyError if open_for?(app.id) || Approval.held?(app.id)

      text = reason.to_s.strip
      raise TooThinError if text.length < SHORTEST_REASON

      row = create!(app_id: app.id, reason: text.first(MAX_REASON))
      Event.record!("access_requested", actor: app.owner_user_id, subject: app.name,
        detail: row.reason)
      row
    end

    def pending? = state == PENDING

    def approve!(by:, note: nil)
      transaction do
        settle!(APPROVED, by, note)
        Approval.grant!(app_id, by: by)
        Event.record!("access_approved", actor: by, subject: app.name,
          detail: "for #{app.owner_user_id}")
      end
      self
    end

    def decline!(by:, note: nil)
      transaction do
        settle!(DECLINED, by, note)
        Event.record!("access_declined", actor: by, subject: app.name,
          detail: "for #{app.owner_user_id}")
      end
      self
    end

    def withdraw!
      settle!(WITHDRAWN, app.owner_user_id, nil)
      self
    end

    private

    def settle!(to, by, note)
      raise AlreadyError unless pending?

      update!(state: to, decided_by: by, decided_at: Time.current,
        note: note.to_s.strip.presence)
    end
  end
end
