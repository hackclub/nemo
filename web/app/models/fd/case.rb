module Fd
  class Case < ApplicationRecord
    self.table_name = "fd.cases"

    RESOLUTION_TABLE = YAML.load_file(Rails.root.join("../db/resolutions.yml"))
      .fetch("resolutions").freeze
    RESOLUTIONS = RESOLUTION_TABLE.keys.freeze
    RESOLUTION_LABELS = RESOLUTION_TABLE.transform_values { |row| row.fetch("label") }.freeze
    CLOSE_REASONS = RESOLUTION_TABLE.select { |_key, row| row["pick"] }
      .sort_by { |_key, row| row["pick"] }.map(&:first).freeze
    def self.category_label(key) = InfractionCategory.label(key)

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
    has_many :case_tags, -> { oldest_first }, class_name: "Fd::CaseTag", foreign_key: :case_id,
      inverse_of: :kase, dependent: nil
    has_many :tags, through: :case_tags

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
    scope :with_live_action_against, ->(user_id) {
      where(id: Action.live.for_target(user_id).select(:case_id))
    }

    PRIOR_WINDOW = 12.months

    def self.priors_for(user_id, within: nil, before: nil)
      actions = Action.where(target_user_id: user_id, reversed_at: nil)
      actions = actions.where(performed_at: ...before) if before
      actions = actions.where(performed_at: ((before || Time.current) - within)..) if within
      where(id: actions.select(:case_id))
    end

    def self.prior_count(user_id, within: nil, before: nil)
      priors_for(user_id, within: within, before: before).count
    end

    def violations
      categories = actions.reject(&:reversed?).filter_map(&:category_key).uniq
      return categories if categories.any?

      [category_key].compact
    end

    def self.violations_for(case_ids)
      ids = case_ids.compact.uniq
      return {} if ids.empty?

      Action.where(case_id: ids, reversed_at: nil).where.not(category_key: nil)
        .distinct.pluck(:case_id, :category_key)
        .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    end

    def self.prior_counts_for(user_ids, within: PRIOR_WINDOW)
      ids = user_ids.compact.uniq
      return {} if ids.empty?

      Action.where(target_user_id: ids, reversed_at: nil)
        .where(performed_at: within.ago..)
        .group(:target_user_id)
        .distinct.count(:case_id)
    end

    def self.open_counts_for(user_ids)
      ids = user_ids.compact.uniq
      return {} if ids.empty?

      CaseParticipant.subjects.where(user_id: ids, case_id: unresolved.select(:id))
        .group(:user_id)
        .distinct.count(:case_id)
    end

    ACTION_TAKEN = "action_taken".freeze

    def self.ending_tally
      closed = where.not(resolved_at: nil)
      by_resolution = closed.group(:resolution).count
      by_action = Action.where(case_id: closed.where(resolution: ACTION_TAKEN).select(:id))
        .group(:type_key).count

      rows = RESOLUTION_TABLE.filter_map do |key, row|
        next if key == ACTION_TAKEN

        count = by_resolution[key].to_i
        [row.fetch("label"), count] if count.positive?
      end

      action_rows = Action::SEVERITY_ORDER.filter_map do |key|
        count = by_action[key].to_i
        [Action::LABELS.fetch(key), count] if count.positive?
      end

      action_rows + rows
    end

    NEARBY_GROUP = "nearby".freeze

    def self.candidate_parts(kase, siblings = [])
      family_ids = kase.family_ids
      shared = siblings.reject { |sibling| family_ids.include?(sibling.id) }
      subject = if kase.subject_user_ids.any?
        with_any_subject(kase.subject_user_ids)
          .where.not(id: family_ids + shared.map(&:id)).order(opened_at: :desc).limit(10).to_a
      else
        []
      end
      [shared, subject, family_ids + shared.map(&:id) + subject.map(&:id)]
    end

    def self.nearby_candidates(excluded_ids, page: 1, per: 8)
      cases = where.not(id: excluded_ids)
        .order(Arel.sql("(resolved_at IS NOT NULL)"), opened_at: :desc, id: :desc)
        .offset((page - 1) * per).limit(per + 1).to_a
      [cases.first(per), cases.size > per]
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

    FAMILY_HOPS = 5

    def self.family_of(root_id, hops: FAMILY_HOPS)
      ids = [root_id]
      frontier = [root_id]

      hops.times do
        frontier = where(duplicate_of: frontier).where.not(id: ids).ids
        break if frontier.empty?

        ids += frontier
      end

      ids
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

    def family_ids
      @family_ids ||= self.class.family_of(id)
    end

    def merged_in
      @merged_in ||= self.class.where(id: family_ids - [id])
        .includes(:subjects).oldest_first.to_a
    end

    def merged?
      merged_in.any?
    end

    def duplicate?
      duplicate_of.present?
    end

    def root
      return self unless duplicate?

      @root ||= self.class.find_by(id: self.class.root_for(id)) || self
    end

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

    def copy_tags_from!(source_case_ids, by:)
      existing_tag_ids = CaseTag.where(case_id: id).select(:tag_id)
      tag_ids = CaseTag.where(case_id: source_case_ids).where.not(tag_id: existing_tag_ids).distinct.pluck(:tag_id)
      return [] if tag_ids.empty?

      CaseTag.insert_all(tag_ids.map { |tag_id| { case_id: id, tag_id: tag_id, added_by: by } })
      Tag.where(id: tag_ids).order(:name).to_a
    end

    def assign!(user_id, by: nil)
      assignees.create!(user_id: user_id, assigned_by: by || user_id, assigned_at: Time.current)
    end

    def mentioned_but_unlogged(notes: [], reports: [])
      mentioned_ids = (notes + reports).flat_map { |record| Mentions.ids(record.body) }.uniq
      return [] if mentioned_ids.empty?

      (mentioned_ids - participants.map(&:user_id) - Account.where(user_id: mentioned_ids).pluck(:user_id)) -
        [opened_by]
    end

    def assignee_handles
      assignee_user_ids.map { |id| "@#{id}" }.to_sentence
    end

    def resolved?
      resolved_at.present?
    end

    def chat_import_pending?
      source_app == "lyla" && chat_imported_at.nil?
    end

    def mark_resolved!(resolution, at:, member_note: nil)
      self.class.where(id: id, resolved_at: nil)
        .update_all(resolved_at: at, resolution: resolution, member_note: member_note, updated_at: at)
        .positive?
    end


    def sibling_cases
      pairs = threads.select(&:evidence?).map(&:coordinates)
      return Case.none if pairs.empty?

      evidence = pairs
        .map { |channel_id, thread_ts| CaseThread.evidence.where(channel_id:, thread_ts:) }
        .reduce { |scope, pair| scope.or(pair) }
      ids = evidence.where.not(case_id: id).distinct.pluck(:case_id)
      ids.any? ? Case.where(id: ids) : Case.none
    end
  end
end
