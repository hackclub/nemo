module Fd
  class AuditEntry < ApplicationRecord
    self.table_name = "fd.audit"

    scope :recent_first, -> { order(occurred_at: :desc, id: :desc) }
    scope :oldest_first, -> { order(:occurred_at, :id) }
    scope :for_entity, ->(type, ids) { where(entity_type: type, entity_id: ids) }

    ERASING = %w[deleted detached unflagged].freeze
    CASE_FILED = %w[participant thread citation].freeze
    LINKING = %w[followed unfollowed].freeze

    def self.decision_links_for(case_id:)
      where(verb: LINKING, entity_type: "case", entity_id: case_id).oldest_first
    end

    def self.erasures_for(case_id:, note_ids: [])
      scope = where(verb: ERASING)
      scope = if note_ids.present?
        scope.where(
          "(entity_type IN (?) AND entity_id IN (?)) OR " \
          "(entity_type = 'note' AND entity_id IN (?))",
          CASE_FILED, Array(case_id), note_ids
        )
      else
        scope.where(entity_type: CASE_FILED, entity_id: Array(case_id))
      end
      scope.oldest_first
    end

    def self.trail_for(case_id:, action_ids: [], report_ids: [])
      pairs = { "case" => Array(case_id), "action" => action_ids, "report" => report_ids }
        .reject { |_type, ids| ids.blank? }
      return none if pairs.empty?

      condition = pairs.keys.map { "(entity_type = ? AND entity_id IN (?))" }.join(" OR ")
      where(condition, *pairs.flat_map { |type, ids| [type, ids] }).oldest_first
    end

    def readonly?
      persisted?
    end

    def by_human?
      actor_kind == "human"
    end

    def actor?
      actor_user_id.present?
    end

    def changed_keys
      (after.presence || {}).keys
    end
  end
end
