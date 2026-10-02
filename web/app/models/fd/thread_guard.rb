module Fd
  class ThreadGuard < ApplicationRecord
    self.table_name = "fd.thread_guards"

    LOCK = "lock".freeze
    DESTROY = "destroy".freeze

    STILL_ON = %w[warned running].freeze

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, optional: true,
      inverse_of: false
    has_many :actions, class_name: "Fd::Action", foreign_key: :thread_guard_id,
      inverse_of: :thread_guard, dependent: :nullify

    scope :still_on, -> { where(state: STILL_ON) }
    scope :locks, -> { where(kind: LOCK) }
    scope :for_case, ->(case_id) { where(case_id: case_id) }
    scope :newest_first, -> { order(created_at: :desc) }

    def self.pickable_locks(case_ids)
      wanted = Array(case_ids).compact
      still_on.locks
        .order(Arel.sql("case_id IS NULL, created_at DESC"))
        .to_a
        .partition { |guard| wanted.include?(guard.case_id) }
        .flatten
    end

    def locking? = kind == LOCK
    def destroying? = kind == DESTROY
    def still_on? = STILL_ON.include?(state)
    def failed? = state == "failed"
    def orphaned? = case_id.nil?

    def on_case?(case_ids) = case_id.present? && Array(case_ids).include?(case_id)

    def attach_to!(case_id)
      won = self.class.still_on.where(id: id, case_id: nil)
        .update_all(case_id: case_id, updated_at: Time.current)
      won.positive? ? reload : nil
    end

    def left_a_note? = note_text.present?

    def people_named
      [opened_by].compact
    end
  end
end
