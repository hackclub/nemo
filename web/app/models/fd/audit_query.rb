module Fd
  class AuditQuery
    Facet = Struct.new(:key, :label, :value, :value_label, :options, :on, :kind,
      keyword_init: true)
    View = Struct.new(:key, :label, :count, :current, keyword_init: true)
    Row = Struct.new(:source, :id, :at, :actor_id, :actor_kind, :verb, :entity_kind,
      :entity_id, :entity_ref, :subject_id, :before, :after, :detail,
      keyword_init: true) do
      def ours? = source == FIRE_ENGINE

      def slack? = source == SLACK

      def read? = source == READ

      def api? = source == API

      def changed_keys
        ((after || {}).keys | (before || {}).keys).sort
      end

      def diff?
        ours? && changed_keys.any?
      end

      def raw
        return after if slack?

        { "before" => before, "after" => after }.compact.presence
      end

      def raw?
        raw.present? || detail.present?
      end

      def was(key) = (before || {})[key]

      def now(key) = (after || {})[key]

      def ip = (detail || {})["ip_address"]

      def app_name = (detail || {}).dig("app", "name")
    end

    FIRE_ENGINE = "fire_engine".freeze
    SLACK = "slack".freeze
    READ = "read".freeze
    API = "api".freeze
    SOURCES = [FIRE_ENGINE, SLACK, READ, API].freeze

    LIMIT = 100
    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/
    WORD = /\A[a-z0-9_.]{2,60}\z/i

    VIEWS = {
      "everything" => "Everything",
      "engine" => "Fire Engine",
      "slack" => "Slack",
      "reads" => "Identity reads",
      "api" => "Public API",
      "refusals" => "Refusals"
    }.freeze

    TABS = VIEWS.keys.freeze

    VIEW_SOURCES = {
      "everything" => SOURCES,
      "engine" => [FIRE_ENGINE],
      "slack" => [SLACK],
      "reads" => [READ],
      "api" => [API],
      "refusals" => [FIRE_ENGINE]
    }.freeze


    TERM_KEY = "q".freeze
    KEYS = %w[view q before_at before_id].freeze

    DEFAULT_VIEW = "slack".freeze
    NO_VIEW = "none".freeze

    HELP = {
      "86.12.44.9" => "an address, and who used it",
      "86.12.44.0/24" => "a range",
      "kid@school.example" => "an email",
      "domain:throwaway.example" => "an email domain",
      "@handle" => "about them",
      "actor:@handle" => "by them",
      "did:deactivated" => "one event",
      "in:#ask" => "one channel",
      "source:slack" => "one log",
      "is:nemo" => "nemo, not a person",
      "after:2026-09-01" => "from a date",
      "before:2026-09-20" => "up to a date",
      "invite spam" => "free text"
    }.freeze

    ONE = {
      FIRE_ENGINE => "a.id::text = :id",
      SLACK => "e.id = :id",
      READ => "'r' || l.id::text = :id"
    }.freeze

    def self.one(source, id)
      return nil unless SOURCES.include?(source) && id.present?

      new({ "when" => "any", "view" => view_for(source) }).send(:pick, source, id)
    end

    def self.view_for(source)
      VIEW_SOURCES.key(Array(source)) || "everything"
    end

    def initialize(params = {}, actor: nil)
      @params = params
      @actor = actor
    end

    attr_reader :actor

    def term
      @term ||= @params[TERM_KEY].to_s.strip
    end

    def search
      @search ||= AuditSearch.parse(term, actor: actor)
    end

    def terms = search.terms

    def asked? = search.any?

    ENGINE_READ = "access.read".freeze

    def may_engine?
      return @may_engine if defined?(@may_engine)

      @may_engine = actor.present? && actor.may?(ENGINE_READ)
    end

    def allowed_views
      return VIEWS if may_engine?

      VIEWS.except(*ENGINE_ONLY)
    end

    ENGINE_ONLY = %w[engine refusals].freeze

    def may_see?(source)
      source != FIRE_ENGINE || may_engine?
    end

    def view
      raw = @params["view"].to_s
      return nil if raw == NO_VIEW

      allowed_views.key?(raw) ? raw : DEFAULT_VIEW
    end

    def view_label = VIEWS.fetch(view)

    def views
      counts = view_counts
      allowed_views.map do |key, label|
        View.new(key: key, label: label, count: counts.fetch(key, 0), current: key == view)
      end
    end

    def carried
      asked? ? { TERM_KEY => term } : {}
    end

    def placed
      return {} if view.nil? || view == DEFAULT_VIEW

      { "view" => view }
    end

    def to_params = carried.merge(placed)

    def view_params(key)
      held = carried
      key == DEFAULT_VIEW ? held : held.merge("view" => key)
    end

    def without_params(one)
      held = carried.merge(placed)
      rest = search.without(one)
      rest.present? ? held.merge(TERM_KEY => rest) : held.except(TERM_KEY)
    end

    def with_params(said)
      carried.merge(placed).merge(TERM_KEY => [term, said].compact_blank.join(" ").strip)
    end

    def rows
      @rows ||= ask(page_sql).map { |row| build(row) }
    end

    def more?
      @more ||= rows.size >= LIMIT
    end

    def next_params
      return nil unless more?

      last = rows.last
      to_params.merge("before_at" => last.at.iso8601(6), "before_id" => last.id)
    end

    def total
      @total ||= ask(count_sql).first["found"].to_i
    end

    def title
      return "#{view_label} matching #{term}" if view && asked?
      return view_label if view

      terms.any? ? "Everything #{terms.map(&:label).to_sentence}" : "Everything"
    end

    def summary
      "#{number_said(rows.size)} of #{counted}"
    end

    COUNT_CEILING = 10_000

    def counted
      total > COUNT_CEILING ? "#{number_said(COUNT_CEILING)}+" : number_said(total)
    end

    def empty_note
      return "Nothing matches that." if asked?

      case view
      when "reads" then "Nobody has looked anybody up."
      when "refusals" then "Nothing has been refused."
      when "slack" then "No Slack audit event has landed yet."
      else "Nothing here yet."
      end
    end

    def suggestions
      known_verbs.first(SUGGESTED)
    end

    SUGGESTED = 12

    KNOWN_VERBS = <<~SQL.squish.freeze
      SELECT DISTINCT verb AS said FROM fd.audit
      UNION
      SELECT DISTINCT action FROM slack.audit_event WHERE NOT ours
      ORDER BY said
    SQL

    def known_verbs
      @known_verbs ||= ApplicationRecord.connection.select_values(KNOWN_VERBS)
    end

    private

    def number_said(count) = ActiveSupport::NumberHelper.number_to_delimited(count)

    def since = Time.zone.at(0)

    def wanted_sources
      held = view ? VIEW_SOURCES.fetch(view) : SOURCES
      asked = search.of("source")
      held = held & asked.map { |one| one == "engine" ? FIRE_ENGINE : one } if asked.any?
      held.select { |source| may_see?(source) }
    end

    def refusals? = view == "refusals"

    ENGINE_BRANCH = <<~SQL.freeze
      SELECT 'fire_engine' AS source, a.id::text AS id, a.occurred_at AS at,
             a.actor_user_id AS actor_id, a.actor_kind AS actor_kind, a.verb AS verb,
             a.entity_type AS entity_kind, a.entity_id::text AS entity_id,
             a.entity_ref AS entity_ref, a.subject_user_id AS subject_id,
             a.before AS before, a.after AS after, NULL::jsonb AS detail
      FROM fd.audit a
      WHERE a.occurred_at >= :since AND (a.verb <> 'refused') = :wanted_kept
        ENGINE_WHERE
    SQL

    SLACK_BRANCH = <<~SQL.freeze
      SELECT 'slack' AS source, e.id AS id, e.at AS at,
             e.actor_id AS actor_id, 'slack' AS actor_kind, e.action AS verb,
             e.entity_kind AS entity_kind, e.entity_id AS entity_id,
             NULL::text AS entity_ref, NULL::text AS subject_id,
             NULL::jsonb AS before, e.payload AS after, e.context AS detail
      FROM slack.audit_event e
      WHERE e.at >= :since AND NOT e.ours
        SLACK_WHERE
    SQL

    READ_BRANCH = <<~SQL.freeze
      SELECT 'read' AS source, 'r' || l.id::text AS id, l.looked_at AS at,
             l.actor_id AS actor_id, 'human' AS actor_kind, 'read' AS verb,
             'identity' AS entity_kind, l.subject_user_id AS entity_id,
             NULL::text AS entity_ref, l.subject_user_id AS subject_id,
             NULL::jsonb AS before, NULL::jsonb AS after,
             jsonb_build_object('field_class', l.field_class) AS detail
      FROM app.access_log l
      WHERE l.looked_at >= :since
        READ_WHERE
    SQL

    API_EVENT_BRANCH = <<~SQL.freeze
      SELECT 'api' AS source, 'ae' || e.id::text AS id, e.at AS at,
             e.actor_user_id AS actor_id, 'human'::text AS actor_kind,
             'api/' || e.verb AS verb,
             'api'::text AS entity_kind, e.subject AS entity_id,
             NULL::text AS entity_ref, NULL::text AS subject_id,
             NULL::jsonb AS before, NULL::jsonb AS after,
             jsonb_strip_nulls(jsonb_build_object('said', e.detail)) AS detail
      FROM api.event_log e
      WHERE e.at >= :since
        API_EVENT_WHERE
    SQL

    API_CONSENT_BRANCH = <<~SQL.freeze
      SELECT 'api' AS source, 'ac' || c.id::text AS id, c.at AS at,
             c.user_id AS actor_id, 'human'::text AS actor_kind,
             'consent/' || c.state AS verb,
             'scope'::text AS entity_kind, c.capability AS entity_id,
             NULL::text AS entity_ref, c.user_id AS subject_id,
             NULL::jsonb AS before, NULL::jsonb AS after,
             jsonb_build_object('via', c.via) AS detail
      FROM api.consent_log c
      WHERE c.at >= :since
        API_CONSENT_WHERE
    SQL

    API_REQUEST_BRANCH = <<~SQL.freeze
      SELECT 'api' AS source, 'ar' || r.id::text AS id, r.at AS at,
             t.owner_user_id AS actor_id, 'app'::text AS actor_kind,
             'api/checked'::text AS verb,
             'channel'::text AS entity_kind, r.channel_id AS entity_id,
             r.channel_id AS entity_ref, r.subject_user_id AS subject_id,
             NULL::jsonb AS before, NULL::jsonb AS after,
             jsonb_build_object('outcome', r.outcome, 'token', t.prefix) AS detail
      FROM api.request_log r
      JOIN api.token t ON t.id = r.token_id
      WHERE r.at >= :since
        API_REQUEST_WHERE
    SQL

    def api_where(at:, actor:, subject:, verb:, kind:, channel: nil)
      parts = []
      parts << "AND #{actor} IN (:actors)" if search.of("actor").any?
      parts << "AND #{subject} IN (:subjects)" if search.of("about").any?
      parts << "AND #{verb} IN (:actions)" if search.of("action").any?
      if search.of("channel").any?
        parts << (channel ? "AND #{channel} IN (:channels)" : "AND false")
      end
      parts << "AND false" if search.text?
      parts << "AND false" if search.of("ip").any?
      if looked_up? && search.of("ip").empty?
        parts << (anybody.any? ? "AND (#{actor} IN (:anybody) OR " \
                                 "#{subject} IN (:anybody))" : "AND false")
      end
      parts << api_doer(actor, kind)
      parts << "AND #{at} >= :after" if search.one("after")
      parts << "AND #{at} < :before" if search.one("before")
      parts.compact.join("\n")
    end

    def api_doer(actor, kind)
      case search.one("is")
      when "human" then kind == "human" ? nil : "AND false"
      when "nemo" then "AND false"
      when "nobody" then "AND #{actor} IS NULL"
      end
    end

    def api_event_where
      api_where(at: "e.at", actor: "e.actor_user_id", subject: "NULL::text",
        verb: "('api/' || e.verb)", kind: "human")
    end

    def api_consent_where
      api_where(at: "c.at", actor: "c.user_id", subject: "c.user_id",
        verb: "('consent/' || c.state)", kind: "human")
    end

    def api_request_where
      api_where(at: "r.at", actor: "t.owner_user_id", subject: "r.subject_user_id",
        verb: "'api/checked'", kind: "app", channel: "r.channel_id")
    end

    def anybody
      @anybody ||= (search.people_for_email + search.people_for_ip).uniq
    end

    def looked_up?
      search.of("email").any? || search.of("domain").any? || search.of("ip").any?
    end

    def nobody_found? = looked_up? && anybody.empty? && search.of("ip").empty?

    def engine_where
      parts = []
      parts << "AND a.actor_user_id IN (:actors)" if search.of("actor").any?
      parts << "AND a.subject_user_id IN (:subjects)" if search.of("about").any?
      parts << "AND a.verb IN (:actions)" if search.of("action").any?
      parts << "AND a.entity_ref IN (:channels)" if search.of("channel").any?
      parts << "AND a.searchable @@ websearch_to_tsquery('simple', :text)" if search.text?
      parts << "AND false" if search.of("ip").any?
      if looked_up? && search.of("ip").empty?
        parts << (anybody.any? ? "AND (a.subject_user_id IN (:anybody) OR " \
                                 "a.actor_user_id IN (:anybody))" : "AND false")
      end
      parts << doer_clause("a.actor_user_id", "a.actor_kind")
      parts << "AND a.occurred_at >= :after" if search.one("after")
      parts << "AND a.occurred_at < :before" if search.one("before")
      parts.compact.join("\n")
    end

    def slack_where
      parts = []
      parts << "AND e.actor_id IN (:actors)" if search.of("actor").any?
      parts << "AND e.entity_id IN (:subjects)" if search.of("about").any?
      parts << "AND e.action IN (:actions)" if search.of("action").any?
      parts << "AND e.entity_id IN (:channels)" if search.of("channel").any?
      parts << "AND e.searchable @@ websearch_to_tsquery('simple', :text)" if search.text?
      parts << ip_clause if search.of("ip").any?
      parts << email_clause if search.of("ip").empty? && looked_up?
      parts << "AND false" if search.one("is") == "nemo"
      parts << "AND e.at >= :after" if search.one("after")
      parts << "AND e.at < :before" if search.one("before")
      parts.compact.join("\n")
    end

    EMAIL_FIELDS = ["payload #>> '{actor,user,email}'",
                    "payload #>> '{entity,user,email}'"].freeze

    def email_clause
      held = []
      search.of("email").each_with_index do |_said, at|
        held.concat(EMAIL_FIELDS.map { |field| "lower(e.#{field}) = :email_#{at}" })
      end
      search.of("domain").each_with_index do |_said, at|
        held.concat(EMAIL_FIELDS.map { |field|
          "lower(split_part(e.#{field}, '@', 2)) = :domain_#{at}"
        })
      end
      held << "e.actor_id IN (:anybody)" if anybody.any?
      held.empty? ? "AND false" : "AND (#{held.join(' OR ')})"
    end

    def ip_clause
      held = search.of("ip").map { |said|
        if said.include?("/")
          "(e.context ->> 'ip_address')::inet << :ip_#{said.hash.abs}::inet"
        else
          "e.context ->> 'ip_address' = :ip_#{said.hash.abs}"
        end
      }
      seen = anybody.any? ? " OR e.actor_id IN (:anybody)" : ""
      "AND ((#{held.join(' OR ')})#{seen})"
    end

    def doer_clause(actor_column, kind_column)
      case search.one("is")
      when "human" then "AND #{kind_column} = 'human' AND #{actor_column} IS NOT NULL"
      when "nemo" then "AND #{kind_column} <> 'human'"
      when "nobody" then "AND #{actor_column} IS NULL"
      end
    end

    def read_where
      parts = []
      parts << "AND l.actor_id IN (:actors)" if search.of("actor").any?
      parts << "AND l.subject_user_id IN (:subjects)" if search.of("about").any?
      parts << "AND false" if search.of("action").any? && search.of("action") != ["read"]
      parts << "AND false" if search.of("channel").any?
      parts << "AND false" if search.text?
      parts << "AND false" if search.of("ip").any?
      if looked_up? && search.of("ip").empty?
        parts << (anybody.any? ? "AND (l.subject_user_id IN (:anybody) OR " \
                                 "l.actor_id IN (:anybody))" : "AND false")
      end
      parts << "AND false" if search.one("is") == "nemo"
      parts << "AND l.looked_at >= :after" if search.one("after")
      parts << "AND l.looked_at < :before" if search.one("before")
      parts.compact.join("\n")
    end

    def branches
      held = []
      if wanted_sources.include?(FIRE_ENGINE)
        held << ENGINE_BRANCH.sub("ENGINE_WHERE", engine_where)
      end
      held << SLACK_BRANCH.sub("SLACK_WHERE", slack_where) if wanted_sources.include?(SLACK)
      held << READ_BRANCH.sub("READ_WHERE", read_where) if wanted_sources.include?(READ)
      if wanted_sources.include?(API)
        held << API_EVENT_BRANCH.sub("API_EVENT_WHERE", api_event_where)
        held << API_CONSENT_BRANCH.sub("API_CONSENT_WHERE", api_consent_where)
        held << API_REQUEST_BRANCH.sub("API_REQUEST_WHERE", api_request_where)
      end
      held
    end

    NOTHING = <<~SQL.freeze
      SELECT NULL::text AS source, NULL::text AS id, NULL::timestamptz AS at,
             NULL::text AS actor_id, NULL::text AS actor_kind, NULL::text AS verb,
             NULL::text AS entity_kind, NULL::text AS entity_id, NULL::text AS entity_ref,
             NULL::text AS subject_id, NULL::jsonb AS before, NULL::jsonb AS after,
             NULL::jsonb AS detail
      WHERE false
    SQL

    COUNTING_PICK = "source".freeze

    def body(where = "true", capped: false, pick: "*")
      held = branches.presence || [NOTHING]
      if capped
        held = held.map { |one| "(SELECT #{pick} FROM (#{one}) one LIMIT #{COUNT_CEILING + 1})" }
      end

      "WITH held AS (\n#{held.join("\nUNION ALL\n")}\n) SELECT * FROM held WHERE #{where}"
    end

    def keyset
      return "true" if before_at.nil?

      "(at, id) < (:before_at::timestamptz, :before_id)"
    end

    def before_at
      said = @params["before_at"].to_s.presence
      return nil if said.nil?

      Time.zone.parse(said)
    rescue ArgumentError
      nil
    end

    def before_id = @params["before_id"].to_s.presence

    def page_sql
      "#{body(keyset)} ORDER BY at DESC, id DESC LIMIT #{LIMIT}"
    end

    def count_sql
      capped = body(capped: true, pick: COUNTING_PICK)
      "SELECT count(*) AS found FROM (#{capped} LIMIT #{COUNT_CEILING + 1}) counted"
    end

    def binds
      held = {
        since: since, text: search.text, before_at: before_at, before_id: before_id,
        wanted_kept: !refusals?,
        actors: search.of("actor").presence || [""],
        subjects: search.of("about").presence || [""],
        actions: search.of("action").presence || [""],
        channels: search.of("channel").presence || [""],
        anybody: anybody.presence || [""],
        after: search.one("after"), before: search.one("before")
      }
      search.of("ip").each { |said| held[:"ip_#{said.hash.abs}"] = said }
      search.of("email").each_with_index { |said, at| held[:"email_#{at}"] = said.downcase }
      search.of("domain").each_with_index { |said, at| held[:"domain_#{at}"] = said.downcase }
      held
    end

    def ask(sql)
      ApplicationRecord.connection.select_all(ApplicationRecord.sanitize_sql([sql, binds]))
    end

    COUNTS = <<~SQL.squish.freeze
      SELECT
        count(*) AS everything,
        count(*) FILTER (WHERE source = 'fire_engine') AS engine,
        count(*) FILTER (WHERE source = 'slack') AS slack,
        count(*) FILTER (WHERE source = 'read') AS reads,
        count(*) FILTER (WHERE source = 'api') AS api,
        0 AS refusals
      FROM held
    SQL

    def view_counts
      @view_counts ||= begin
        whole = self.class.new(@params.except("view").merge("view" => NO_VIEW), actor: actor)
        row = ApplicationRecord.connection.select_one(
          ApplicationRecord.sanitize_sql([whole.send(:counting_sql), whole.send(:binds)])
        ) || {}
        VIEWS.keys.index_with { |key| row[key].to_i }
      end
    end

    def counting_sql
      capped = body(capped: true, pick: COUNTING_PICK)
      "#{capped.sub(/SELECT \* FROM held WHERE true\z/, '')}#{COUNTS}"
    end

    def held_json(value)
      return value if value.is_a?(Hash)
      return nil if value.blank?

      JSON.parse(value)
    rescue JSON::ParserError
      nil
    end

    def pick(source, id)
      branch = case source
      when FIRE_ENGINE then ENGINE_BRANCH.sub("ENGINE_WHERE", "AND a.id::text = :id")
      when SLACK then SLACK_BRANCH.sub("SLACK_WHERE", "AND e.id = :id")
      when READ then READ_BRANCH.sub("READ_WHERE", "AND 'r' || l.id::text = :id")
      else api_branch_for(id)
      end
      found = ApplicationRecord.connection.select_all(
        ApplicationRecord.sanitize_sql([branch, binds.merge(id: id, since: Time.zone.at(0))])
      ).first
      found && build(found)
    end

    def api_branch_for(id)
      case id.to_s[0, 2]
      when "ae" then API_EVENT_BRANCH.sub("API_EVENT_WHERE", "AND 'ae' || e.id::text = :id")
      when "ac" then API_CONSENT_BRANCH.sub("API_CONSENT_WHERE", "AND 'ac' || c.id::text = :id")
      else API_REQUEST_BRANCH.sub("API_REQUEST_WHERE", "AND 'ar' || r.id::text = :id")
      end
    end

    def build(row)
      Row.new(
        source: row["source"], id: row["id"], at: row["at"], actor_id: row["actor_id"],
        actor_kind: row["actor_kind"], verb: row["verb"], entity_kind: row["entity_kind"],
        entity_id: row["entity_id"], entity_ref: row["entity_ref"],
        subject_id: row["subject_id"], before: held_json(row["before"]),
        after: held_json(row["after"]), detail: held_json(row["detail"])
      )
    end
  end
end
