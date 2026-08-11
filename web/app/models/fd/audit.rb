module Fd
  class Audit
    SOURCE_APP = "fire_engine".freeze

    ENTITY_TYPES = {
      "Fd::Case" => "case",
      "Fd::Action" => "action",
      "Fd::Note" => "note",
      "Fd::CaseReport" => "report",
      "Fd::CaseThread" => "thread",
    }.freeze

    VERBS = %w[
      opened claimed unclaimed resolved reopened
      performed reversed received
      noted deleted attached detached
    ].freeze

    REDACTED_COLUMNS = {
      "note" => %w[body],
      "case" => %w[member_note],
    }.freeze

    IGNORED_COLUMNS = %w[id created_at updated_at].freeze

    class UnauditableRecord < ArgumentError; end
    class UnknownVerb < ArgumentError; end

    def self.record(record, verb, actor:, request_id: nil, actor_kind: "human",
      source_app: SOURCE_APP, before: nil, after: nil)
      type = entity_type(record)
      raise UnknownVerb, "#{verb} is not an audited verb" unless VERBS.include?(verb)

      changes = record.previous_changes.except(*IGNORED_COLUMNS)

      AuditEntry.create!(
        actor_user_id: actor,
        actor_kind: actor_kind,
        entity_type: type,
        entity_id: record.id,
        verb: verb,
        before: redact(type, before || previous_values(record, changes)),
        after: redact(type, after || changes.transform_values(&:last)),
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
