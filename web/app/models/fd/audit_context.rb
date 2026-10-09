module Fd
  class AuditContext
    RELATED = 10
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    Device = Struct.new(:app, :os, :ua, keyword_init: true)
    Place = Struct.new(:country, :network, :kind, keyword_init: true)

    CONTEXT_SQL = <<~SQL.squish.freeze
      SELECT u.ua, u.app, u.os, n.country, n.network, n.class AS kind
      FROM (SELECT ua_id, ip FROM slack.audit_event WHERE id = :id
            UNION ALL
            SELECT ua_id, ip FROM slack.audit_view WHERE id = :id) e
      LEFT JOIN slack.user_agent u ON u.id = e.ua_id
      LEFT JOIN fd.ip_network n
        ON n.ip_prefix = network(set_masklen(e.ip, CASE WHEN family(e.ip) = 4 THEN 24 ELSE 64 END))
      LIMIT 1
    SQL

    def initialize(row, query)
      @row = row
      @query = query
    end

    attr_reader :row

    def device
      return nil unless found

      held = Device.new(app: found["app"], os: found["os"], ua: found["ua"])
      held.ua || held.app ? held : nil
    end

    def place
      return nil unless found && @query.identity?

      held = Place.new(country: found["country"], network: found["network"], kind: found["kind"])
      held.country || held.network ? held : nil
    end

    def actor_email = payload.dig("actor", "user", "email")

    def entity_name
      kind = payload.dig("entity", "type")
      return nil if kind.blank?

      held = payload.dig("entity", kind)
      held.is_a?(Hash) ? (held["name"].presence || held["title"].presence) : nil
    end

    def category
      key = AuditCatalogue::ACTIONS.dig(row.verb.to_s, "category")
      key && AuditCatalogue.category_label(key)
    end

    def related_params
      around = @query.pivots(row).find { |one| one.kind == "around" }
      around&.params
    end

    def related
      @related ||= begin
        params = related_params
        params ? AuditQuery.new(params, actor: @query.actor).rows.reject { |one| one.id == row.id } : []
      end
    end

    def shown_related = related.first(RELATED)

    def more_related? = related.size > RELATED

    private

    def payload
      row.slack? && row.after.is_a?(Hash) ? row.after : {}
    end

    def found
      return @found if defined?(@found)

      @found = row.slack? && row.id.to_s.match?(UUID) ? lookup : nil
    end

    def lookup
      ApplicationRecord.connection.select_one(ApplicationRecord.sanitize_sql([CONTEXT_SQL, { id: row.id }]))
    end
  end
end
