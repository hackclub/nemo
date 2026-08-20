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

    CATEGORY_LABELS = {
      "nos" => "Misconduct not otherwise specified",
      "adult" => "Adult",
      "insulting" => "Insulting or demeaning remarks",
      "bullying" => "Bullying",
      "discrimination" => "Discrimination",
      "hateful" => "Hateful remarks",
      "harassment_identity" => "Systematic harassment, identity based",
      "harassment_general" => "Systematic harassment, general",
      "nsfw_mild" => "Mild or ambiguous NSFW",
      "nsfw_extreme" => "Clear and extreme NSFW",
      "advertising" => "Advertising or recruiting",
      "spam" => "Spam",
      "fraud_hcb" => "HCB fraud",
      "fraud_referral" => "Referral fraud",
      "fraud_ysws" => "YSWS fraud",
      "fraud_other" => "Other fraud",
      "ban_evasion" => "Slack ban evasion"
    }.freeze

    def self.category_label(key)
      CATEGORY_LABELS.fetch(key) { key.to_s.tr("_", " ") }
    end

    has_many :threads, class_name: "Fd::CaseThread", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil
    has_many :participants, class_name: "Fd::CaseParticipant", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil
    has_many :subjects, -> { subjects.order(:user_id) },
      class_name: "Fd::CaseParticipant", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil
    has_many :assignees, -> { oldest_first }, class_name: "Fd::CaseAssignee",
      foreign_key: :case_id, inverse_of: :kase, dependent: nil
    has_many :reports, class_name: "Fd::CaseReport", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil
    has_many :actions, class_name: "Fd::Action", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil
    has_many :notes, class_name: "Fd::Note", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil
    has_many :citations, -> { oldest_first }, class_name: "Fd::CaseCitation",
      foreign_key: :case_id, inverse_of: :kase, dependent: nil
    belongs_to :followed_decision, class_name: "Fd::Decision",
      foreign_key: :followed_decision_id, inverse_of: :cases_followed, optional: true

    scope :unresolved, -> { where(resolved_at: nil) }
    scope :not_duplicate, -> { where(duplicate_of: nil) }
    scope :with_subject, ->(user_id) {
      where(id: CaseParticipant.subjects.where(user_id: user_id).select(:case_id))
    }
    scope :with_any_subject, ->(user_ids) {
      where(id: CaseParticipant.subjects.where(user_id: user_ids).select(:case_id))
    }
    scope :assigned_to, ->(user_id) {
      where(id: CaseAssignee.where(user_id: user_id).select(:case_id))
    }
    scope :unassigned, -> {
      where.not(id: CaseAssignee.select(:case_id))
    }
    scope :free_or_assigned_to, ->(user_id) {
      unassigned.or(assigned_to(user_id))
    }
    scope :with_live_action_against, ->(user_id) {
      where(id: Action.live.for_target(user_id).select(:case_id))
    }

    PRIOR_WINDOW = 12.months

    def self.priors_for(user_id, within: nil, before: nil)
      scope = where.not(resolved_at: nil)
        .with_subject(user_id)
        .with_live_action_against(user_id)
      scope = scope.where(resolved_at: ...before) if before
      scope = scope.where(resolved_at: ((before || Time.current) - within)..) if within
      scope
    end

    def self.prior_count(user_id, within: nil, before: nil)
      priors_for(user_id, within: within, before: before).count
    end

    def self.prior_counts_for(user_ids, within: PRIOR_WINDOW)
      ids = user_ids.compact.uniq
      return {} if ids.empty?

      CaseParticipant.subjects
        .where(user_id: ids)
        .where(case_id: where(resolved_at: within.ago..).select(:id))
        .where(<<~SQL.squish)
          EXISTS (
            SELECT 1 FROM fd.actions a
            WHERE a.case_id = fd.case_participants.case_id
              AND a.target_user_id = fd.case_participants.user_id
              AND a.reversed_at IS NULL
          )
        SQL
        .group(:user_id).count
    end

    def self.thread_message_counts_for(case_ids)
      ids = case_ids.compact.uniq
      return {} if ids.empty?

      CaseThread.where(case_id: ids)
        .joins(<<~SQL.squish)
          JOIN fd.thread_messages tm
            ON tm.channel_id = fd.case_threads.channel_id
           AND tm.thread_ts = fd.case_threads.thread_ts
        SQL
        .group(:case_id).count
    end

    def self.thread_channels_for(case_ids)
      ids = case_ids.compact.uniq
      return {} if ids.empty?

      CaseThread.where(case_id: ids).pluck(:case_id, :channel_id)
        .group_by(&:first).transform_values { |pairs| pairs.map(&:last).uniq }
    end

    def self.candidates_for(kase, siblings = [], limit: 25)
      ordered = siblings.map(&:id)
      kase.subject_user_ids.each do |user_id|
        ordered += with_subject(user_id)
          .where.not(id: kase.id).order(opened_at: :desc).limit(10).ids
      end
      ordered += unresolved.where.not(id: kase.id).order(opened_at: :desc).limit(15).ids
      ordered = (ordered.uniq - [kase.id]).first(limit)

      by_id = where(id: ordered).includes(:subjects).index_by(&:id)
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

    def subject_user_ids
      subjects.map(&:user_id)
    end

    def subject_user_id
      subject_user_ids.first
    end

    def add_subject!(user_id)
      subjects.create!(user_id: user_id, role: "subject")
    end

    def assignee_user_ids
      assignees.map(&:user_id)
    end

    def assigned?
      assignees.any?
    end

    def assigned_to?(user_id)
      assignee_user_ids.include?(user_id)
    end

    def assign!(user_id, by: nil)
      assignees.create!(user_id: user_id, assigned_by: by || user_id, assigned_at: Time.current)
    end

    def mentioned_but_unlogged(notes: [], reports: [])
      said = (notes + reports).flat_map { |row| Mentions.ids(row.body) }.uniq
      return [] if said.empty?

      (said - participants.map(&:user_id) - Staff.where(user_id: said).pluck(:user_id)) -
        [opened_by]
    end

    def mine_or_free?(user_id)
      !assigned? || assigned_to?(user_id)
    end

    def assignee_handles
      assignee_user_ids.map { |id| "@#{id}" }.to_sentence
    end

    def resolved?
      resolved_at.present?
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
