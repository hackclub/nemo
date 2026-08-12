module Fd
  class Case < ApplicationRecord
    self.table_name = "fd.cases"

    RESOLUTIONS = %w[action_taken no_action duplicate not_conduct].freeze
    CLOSE_REASONS = %w[not_conduct no_action].freeze
    CATEGORIES = %w[
      nos adult insulting bullying discrimination hateful
      harassment_identity harassment_general nsfw_mild nsfw_extreme
      advertising spam fraud_hcb fraud_referral fraud_ysws fraud_other
      ban_evasion
    ].freeze

    has_many :threads, class_name: "Fd::CaseThread", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil
    has_many :participants, class_name: "Fd::CaseParticipant", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil
    has_many :reports, class_name: "Fd::CaseReport", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil
    has_many :actions, class_name: "Fd::Action", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil
    has_many :notes, class_name: "Fd::Note", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil

    scope :unresolved, -> { where(resolved_at: nil) }
    scope :not_duplicate, -> { where(duplicate_of: nil) }

    def self.candidates_for(kase, siblings = [], limit: 25)
      ordered = siblings.map(&:id)
      if kase.subject_user_id
        ordered += where(subject_user_id: kase.subject_user_id)
          .where.not(id: kase.id).order(opened_at: :desc).limit(10).ids
      end
      ordered += unresolved.where.not(id: kase.id).order(opened_at: :desc).limit(15).ids
      ordered = (ordered.uniq - [kase.id]).first(limit)

      by_id = where(id: ordered).index_by(&:id)
      ordered.filter_map { |id| by_id[id] }
    end

    def self.root_for(id, hops: 10)
      current = id
      hops.times do
        parent = where(id: current).pick(:duplicate_of)
        break if parent.nil?

        current = parent
      end
      current
    end
    scope :oldest_first, -> { order(:opened_at) }
    scope :newest_first, -> { order(opened_at: :desc) }

    def resolved?
      resolved_at.present?
    end

    def claimed?
      claimed_by.present?
    end

    def primary_thread
      threads.detect(&:is_primary)
    end

    def sibling_cases
      pairs = threads.evidence.map(&:coordinates)
      return Case.none if pairs.empty?

      tuples = Array.new(pairs.size, "(?, ?)").join(", ")
      ids = CaseThread.evidence
        .where("(channel_id, thread_ts) IN (#{tuples})", *pairs.flatten)
        .where.not(case_id: id)
        .distinct
        .pluck(:case_id)
      ids.any? ? Case.where(id: ids) : Case.none
    end
  end
end
