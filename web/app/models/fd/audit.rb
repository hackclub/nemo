module Fd
  class Audit
    SOURCE_APP = "fire_engine".freeze

    ENTITY_TYPES = {
      "Fd::Case" => "case",
      "Fd::Action" => "action",
      "Fd::Note" => "note",
      "Fd::CaseReport" => "report",
      "Fd::CaseThread" => "thread",
      "Fd::CaseParticipant" => "participant",
      "Fd::CaseAssignee" => "assignee",
      "Fd::MemberIdentity" => "identity",
      "Fd::CaseCitation" => "citation",
      "Fd::Decision" => "decision",
      "Fd::DecisionThread" => "decision_thread",
      "Fd::AccessGrant" => "grant",
      "Fd::RolePermission" => "permission",
      "Fd::StaffSlack" => "slack_account"
    }.freeze

    VERBS = %w[
      opened claimed unclaimed resolved reopened categorised
      performed reversed received
      noted deleted attached detached flagged unflagged closed answered
      proposed settled amended superseded dropped followed unfollowed
      granted revoked refused
      linked unlinked
    ].freeze

    REDACTED_COLUMNS = {
      "note" => %w[body],
      "case" => %w[member_note],
      "identity" => %w[real_name first_name last_name email],
      "slack_account" => %w[user_token]
    }.freeze

    IGNORED_COLUMNS = %w[id created_at updated_at].freeze

    class UnauditableRecord < ArgumentError; end
    class UnknownVerb < ArgumentError; end

    def self.record(record, verb, actor:, request_id: nil, actor_kind: "human",
      source_app: SOURCE_APP, entity_id: nil, before: nil, after: nil)
      type = entity_type(record)
      raise UnknownVerb, "#{verb} is not an audited verb" unless VERBS.include?(verb)

      changes = record.previous_changes.except(*IGNORED_COLUMNS)

      AuditEntry.create!(
        actor_user_id: actor,
        actor_kind: actor_kind,
        entity_type: type,
        entity_id: entity_id || record.id,
        verb: verb,
        before: redact(type, before || previous_values(record, changes)),
        after: redact(type, after || next_values(record, changes)),
        source_app: source_app,
        request_id: request_id,
      )
    end

    def self.entity_type(record)
      ENTITY_TYPES.fetch(record.class.name) do
        raise UnauditableRecord, "#{record.class.name} is not a conduct record"
      end
    end

    def self.previous_values(record, changes)
      return nil if record.previously_new_record?

      changes.transform_values(&:first)
    end

    def self.next_values(record, changes)
      return changes.transform_values(&:last) unless record.previously_new_record?

      record.attributes.except(*IGNORED_COLUMNS).compact
    end

    def self.redact(type, payload)
      return nil if payload.blank?

      columns = REDACTED_COLUMNS.fetch(type, [])
      return payload if columns.empty?

      payload.to_h { |key, value| [key, columns.include?(key.to_s) ? summarise(value) : value] }
    end

    def self.summarise(value)
      return nil if value.nil?

      "redacted, #{value.to_s.length} chars"
    end
  end
end
