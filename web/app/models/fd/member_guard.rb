module Fd
  class MemberGuard < ApplicationRecord
    self.table_name = "fd.member_guards"

    SHUSH = "shush".freeze
    CHANNEL_BAN = "channel_ban".freeze
    DEACTIVATION = "deactivation".freeze
    KINDS = [SHUSH, CHANNEL_BAN, DEACTIVATION].freeze

    UNDONE_IN_SLACK = [DEACTIVATION].freeze
    DATELESS = [DEACTIVATION].freeze
    HOLDS = (KINDS - [DEACTIVATION]).freeze
    WORST_KINDS = [DEACTIVATION, CHANNEL_BAN, SHUSH].freeze

    LIVE = "live".freeze
    LIFTING = "lifting".freeze
    LIFTED = "lifted".freeze
    STILL_ON = [LIVE, LIFTING].freeze

    PENDING = "pending".freeze
    HELD = "held".freeze
    FAILED = "failed".freeze

    NEMO = "nemo".freeze
    BY_HAND = "by_hand".freeze

    CARRY = "carry".freeze
    ALREADY_DONE = "by_hand".freeze
    ADOPT = "adopt".freeze
    EXTEND = "extend".freeze
    RECORD = "record".freeze

    UNGUARDED = :unguarded
    ORPHANED = :orphaned
    ELSEWHERE = :elsewhere
    HERE = :here

    FRESH = 20.seconds

    has_many :events, class_name: "Fd::MemberGuardEvent", foreign_key: :guard_id,
      inverse_of: :guard, dependent: :destroy
    has_many :actions, class_name: "Fd::Action", foreign_key: :guard_id,
      inverse_of: :guard, dependent: :nullify
    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, optional: true,
      inverse_of: false

    scope :still_on, -> { where(state: STILL_ON) }
    scope :live, -> { where(state: LIVE) }
    scope :on_no_case, -> { where(case_id: nil) }
    scope :orphaned, -> { live.on_no_case }
    scope :stuck, -> { where(enforcement_status: FAILED) }
    scope :oldest_first, -> { order(:opened_at, :id) }
    scope :for_subject, ->(subject_id) { where(subject_id: subject_id) }

    Standing = Struct.new(:enforceable, :guard, :reads, :case_id, keyword_init: true) do
      def found? = guard.present?
      def enforceable? = enforceable
    end

    def self.settle(type_key, subject_id, case_id: nil, channel_id: nil)
      unless Action.enforceable?(type_key)
        return Standing.new(enforceable: false, guard: nil, reads: UNGUARDED, case_id: case_id)
      end

      guard = subject_id.present? ? for_action(type_key, subject_id, channel_id: channel_id) : nil
      Standing.new(enforceable: true, guard: guard, case_id: case_id,
        reads: guard ? guard.reads_for(case_id) : UNGUARDED)
    end

    def self.standing_on(subject_id)
      subject = subject_id.to_s.upcase.presence
      return [] if subject.nil?

      still_on.for_subject(subject).oldest_first.to_a
    end

    def self.worst_kinds_first(kinds)
      Array(kinds).uniq.sort_by { |kind| WORST_KINDS.index(kind) || WORST_KINDS.size }
    end

    def self.worst_first(guards)
      weight = Action::WORST_FIRST
      guards.sort_by { |guard| [weight.index(guard.kind) || weight.size, -guard.opened_at.to_i] }
    end

    def self.standing_for(subject_id, kind:, channel_id: nil)
      still_on.find_by(subject_id: subject_id, kind: kind, channel_id: channel_id)
    end

    def self.for_action(type_key, subject_id, channel_id: nil)
      kind = Action.guard_kind(type_key)
      return nil if kind.nil?

      where = Action.guard_scope(type_key) == "channel" ? channel_id : nil
      standing_for(subject_id, kind: kind, channel_id: where)
    end

    def self.open!(kind:, subject_id:, by:, reason:, channel_id: nil, case_id: nil,
      expires_at: nil, by_hand: false)
      transaction(requires_new: true) do
        create!(kind: kind, subject_id: subject_id, channel_id: channel_id, case_id: case_id,
          opened_by: by, reason: reason, expires_at: expires_at,
          enforced_by: by_hand ? BY_HAND : NEMO, enforcement_status: by_hand ? HELD : PENDING)
      end
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def attach_to!(case_id)
      won = self.class.still_on.where(id: id, case_id: nil)
        .update_all(case_id: case_id, updated_at: Time.current)
      won.positive? ? reload : nil
    end

    def run_until!(expires_at)
      won = self.class.still_on.where(id: id)
        .update_all(expires_at: expires_at, updated_at: Time.current)
      won.positive? ? reload : nil
    end

    def lift!(by:, reason: nil)
      won = self.class.still_on.where(id: id).update_all(
        **lifting_columns, lifted_by: by, lift_reason: reason, updated_at: Time.current
      )
      won.positive? ? reload : nil
    end

    def undone_in_slack?
      UNDONE_IN_SLACK.include?(kind) && !by_hand?
    end

    def dateless? = DATELESS.include?(kind)

    def live? = state == LIVE
    def lifting? = state == LIFTING
    def held? = enforcement_status == HELD
    def pending? = enforcement_status == PENDING
    def failed? = enforcement_status == FAILED
    def by_hand? = enforced_by == BY_HAND
    def orphaned? = case_id.nil?
    def channel_scoped? = channel_id.present?
    def deactivation? = kind == DEACTIVATION

    def enforcement_state
      lifting? ? LIFTING : enforcement_status
    end

    def landed?(at = Time.current)
      updated_at.present? && updated_at > at - FRESH
    end

    def on_case?(case_ids) = case_id.present? && Array(case_ids).include?(case_id)

    def reads_for(on_case_id)
      return ORPHANED if orphaned?
      return HERE if on_case_id.present? && case_id == on_case_id

      ELSEWHERE
    end

    def people_named
      [opened_by, lifted_by].compact
    end

    private

    def lifting_columns
      return { state: LIFTING } if undone_in_slack?

      { state: LIFTED, lifted_at: Time.current }
    end
  end
end
