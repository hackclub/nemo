module Fd
  class AuditEntry < ApplicationRecord
    self.table_name = "fd.audit"

    scope :recent_first, -> { order(occurred_at: :desc, id: :desc) }
    scope :oldest_first, -> { order(:occurred_at, :id) }
    scope :for_entity, ->(type, ids) { where(entity_type: type, entity_id: ids) }

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
