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
    KEYS = %w[view q before_at before_id after_at after_id on].freeze

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
      "category:people" => "one kind of event",
      "show:high_volume" => "previews, downloads and list edits",
      "in:#ask" => "one channel",
      "source:slack" => "one log",
      "is:nemo" => "nemo, not a person",
      "after:2026-09-01" => "from a date",
      "before:2026-09-20" => "up to a date",
      "last:24h" => "the last 24 hours",
      "invite spam" => "free text"
    }.freeze

    ONE = {
      FIRE_ENGINE => "a.id::text = :id",
      SLACK => "e.id::text = :id",
      READ => "'r' || l.id::text = :id"
    }.freeze

    def self.one(source, id, actor: nil)
      return nil unless SOURCES.include?(source) && id.present?

      new({ "when" => "any", "view" => view_for(source) }, actor: actor).send(:pick, source, id)
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
    SLACK_READ = "audit.read".freeze
    IDENTITY_READ = "identity.read".freeze

    def may_engine?
      return @may_engine if defined?(@may_engine)

      @may_engine = actor.present? && actor.may?(ENGINE_READ)
    end

    def may_slack?
      return @may_slack if defined?(@may_slack)

      @may_slack = actor.present? && actor.may?(SLACK_READ)
    end

    def identity? = search.identity?

    def identity_refused? = search.identity_terms? && !identity?

    def allowed_views
      held = VIEWS
      held = held.except(*ENGINE_ONLY) unless may_engine?
      held = held.except(*SLACK_ONLY) unless may_slack?
      held
    end

    ENGINE_ONLY = %w[engine refusals].freeze
    SLACK_ONLY = %w[slack].freeze

    def may_see?(source)
      case source
      when FIRE_ENGINE then may_engine?
      when SLACK then may_slack?
      else true
      end
    end

    def default_view = may_slack? ? DEFAULT_VIEW : "everything"

    def view
      raw = @params["view"].to_s
      return nil if raw == NO_VIEW

      allowed_views.key?(raw) ? raw : default_view
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
      return {} if view.nil? || view == default_view

      { "view" => view }
    end

    def to_params = carried.merge(placed)

    def view_params(key)
      held = carried
      key == default_view ? held : held.merge("view" => key)
    end

    def without_params(one)
      held = carried.merge(placed)
      rest = search.without(one)
      rest.present? ? held.merge(TERM_KEY => rest) : held.except(TERM_KEY)
    end

    def with_params(term_value)
      carried.merge(placed).merge(TERM_KEY => [term, term_value].compact_blank.join(" ").strip)
    end

    RANGE_KINDS = %w[after before last].freeze
    HOUR = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/

    def range_params(start_on, end_on)
      start = start_on.to_s
      ending = end_on.presence&.to_s || start
      kept = terms.reject { |one| RANGE_KINDS.include?(one.kind) }.map { |one| search.label_for(one) }
      placed.merge(TERM_KEY => (kept + range_terms(start, ending)).join(" "))
    rescue Date::Error, ArgumentError, NoMethodError
      to_params
    end

    def range_terms(start, ending)
      if start.match?(HOUR) && ending.match?(HOUR)
        from, upto = [Time.zone.parse(start), Time.zone.parse(ending)].minmax
        return ["after:#{from.strftime(AuditSearch::MINUTE)}", "before:#{(upto + 1.hour).strftime(AuditSearch::MINUTE)}"]
      end

      from, upto = [Date.iso8601(start), Date.iso8601(ending)].minmax
      ["after:#{from.iso8601}", "before:#{(upto + 1).iso8601}"]
    end

    def set_params(kinds, value = nil)
      kinds = Array(kinds)
      kept = terms.reject { |one| kinds.include?(one.kind) }.map { |one| search.label_for(one) }
      kept << "#{kinds.first}:#{value}" if value
      held = placed
      kept.any? ? held.merge(TERM_KEY => kept.join(" ")) : held
    end

    def rows
      @rows ||= paged_rows
    end

    def back_params
      return nil if rows.empty? || first_page?

      first = rows.first
      to_params.merge("after_at" => first.at.iso8601(6), "after_id" => first.id)
    end

    def looked_at
      held = {}
      held["identity_search"] = shown_people if search.identity_terms? && identity?
      held["audit"] = search.of("actor") | search.of("about") if wanted_sources.include?(SLACK)
      held.transform_values { |ids| ids.grep(MEMBER_ID) }.reject { |_, ids| ids.empty? }
    end

    def shown_people
      rows.flat_map { |row| [row.actor_id, row.subject_id, row.entity_id] }.compact.uniq
    end

    def jump_on
      Date.iso8601(@params["on"].to_s)
    rescue Date::Error
      nil
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

    HISTOGRAM_DAYS = 30
    HOURLY_UP_TO = 2.days
    FIRST_DAY = Date.new(2025, 11, 1)
    HISTOGRAM_TIMEOUT = "SET LOCAL statement_timeout = '8s'".freeze
    HISTOGRAM_WINDOW = "at >= :histogram_from AND at < :histogram_upto".freeze

    def histogram_span
      upto = [upto_at, Time.current].compact.min
      from = from_at || (upto.to_date - (HISTOGRAM_DAYS - 1)).in_time_zone
      [[from, FIRST_DAY.in_time_zone].max, upto]
    end

    def hourly?
      from, upto = histogram_span
      upto - from <= HOURLY_UP_TO
    end

    def histogram
      from, upto = histogram_span
      return [] if from >= upto || wanted_sources.empty?

      unit = hourly? ? "hour" : "day"
      found = ApplicationRecord.transaction do
        ApplicationRecord.connection.execute(HISTOGRAM_TIMEOUT)
        ask(histogram_sql, unit: unit, zone: Time.zone.tzinfo.name, histogram_from: from, histogram_upto: upto)
          .to_h { |row| [bin_key(row["bin"]), row["found"].to_i] }
      end
      histogram_bins(from, upto).map { |bin| [bin, found.fetch(bin_key(bin), 0)] }
    rescue ActiveRecord::QueryCanceled
      []
    end

    def histogram_bins(from, upto)
      return (from.to_date..(upto - 1).to_date).to_a unless hourly?

      first = from.beginning_of_hour
      (0...((upto - first) / 1.hour).ceil).map { |step| first + step.hours }
    end

    def bin_key(value)
      at = value.is_a?(String) ? Time.zone.parse(value) : value
      hourly? ? at.strftime(AuditSearch::MINUTE) : at.to_date.iso8601
    end

    def title
      return "#{view_label} matching #{term}" if view && asked?
      return view_label if view

      terms.any? ? "Everything #{terms.map(&:label).to_sentence}" : "Everything"
    end

    def summary
      "#{number_label(rows.size)} of #{counted}"
    end

    COUNT_CEILING = 10_000

    def counted
      total > COUNT_CEILING ? "#{number_label(COUNT_CEILING)}+" : number_label(total)
    end

    def empty_note
      return "Not yours to search by address or email" if identity_refused?
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
      SELECT DISTINCT verb FROM fd.audit
      UNION
      SELECT DISTINCT action FROM slack.audit_event WHERE NOT ours
      UNION
      SELECT action FROM slack.audit_view_action
      ORDER BY verb
    SQL

    def known_verbs
      @known_verbs ||= ApplicationRecord.connection.select_values(KNOWN_VERBS)
    end

    private

    def number_label(count) = ActiveSupport::NumberHelper.number_to_delimited(count)

    def since = Time.zone.at(0)

    def wanted_sources
      return [] if identity_refused?

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
      SELECT 'slack' AS source, e.id::text AS id, e.at AS at,
             e.actor_id AS actor_id, 'slack' AS actor_kind, e.action AS verb,
             e.entity_kind AS entity_kind, e.entity_id AS entity_id,
             NULL::text AS entity_ref, NULL::text AS subject_id,
             NULL::jsonb AS before, e.payload AS after, e.payload -> 'context' AS detail
      FROM slack.audit_event e
      WHERE e.at >= :since AND NOT e.ours
        SLACK_WHERE
    SQL

    SLACK_VIEW_BRANCH = <<~SQL.freeze
      SELECT 'slack' AS source, v.id::text AS id, v.at AS at,
             v.actor_id AS actor_id, 'slack' AS actor_kind, a.action AS verb,
             a.entity_kind AS entity_kind, v.object_id AS entity_id,
             NULL::text AS entity_ref, NULL::text AS subject_id,
             NULL::jsonb AS before, NULL::jsonb AS after,
             jsonb_strip_nulls(jsonb_build_object('ip_address', host(v.ip), 'ua', u.ua,
               'session_id', v.session_id)) AS detail
      FROM slack.audit_view v
      JOIN slack.audit_view_action a ON a.code = v.action
      LEFT JOIN slack.user_agent u ON u.id = v.ua_id
      WHERE v.at >= :since AND NOT v.ours
        SLACK_VIEW_WHERE
    SQL

    SLACK_SEARCHED = <<~SQL.squish.freeze
      to_tsvector('simple'::regconfig,
        coalesce(action, '') || ' ' || coalesce(actor_id, '') || ' ' ||
        coalesce(entity_id, '') || ' ' || coalesce(entity_kind, '') || ' ' ||
        coalesce(host(ip), '') || ' ' || coalesce(payload #>> '{context,app,name}', '') || ' ' ||
        coalesce(actor_email, '') || ' ' || coalesce(payload #>> '{actor,user,name}', '') || ' ' ||
        coalesce(entity_email, '') || ' ' || coalesce(payload #>> '{entity,user,name}', '') || ' ' ||
        coalesce(payload #>> '{entity,channel,name}', ''))
    SQL

    SLACK_VIEW_SEARCHED = <<~SQL.squish.freeze
      to_tsvector('simple'::regconfig,
        a.action || ' ' || coalesce(v.actor_id, '') || ' ' || coalesce(v.object_id, '') || ' ' ||
        coalesce(host(v.ip), ''))
    SQL

    VIEW_ACTIONS = <<~SQL.squish.freeze
      SELECT action FROM slack.audit_view_action
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
             jsonb_strip_nulls(jsonb_build_object('note', e.detail)) AS detail
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
      parts << "AND false" if search.of("category").any?
      if looked_up? && search.of("ip").empty?
        parts << (anybody.any? ? "AND (#{actor} IN (:anybody) OR " \
                                 "#{subject} IN (:anybody))" : "AND false")
      end
      parts << api_doer(actor, kind)
      parts << "AND #{at} >= :after" if from_at
      parts << "AND #{at} < :before" if upto_at
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
      parts << "AND false" if search.of("category").any?
      parts << "AND a.searchable @@ websearch_to_tsquery('simple', :text)" if search.text?
      parts << "AND false" if search.of("ip").any?
      if looked_up? && search.of("ip").empty?
        parts << (anybody.any? ? "AND (a.subject_user_id IN (:anybody) OR " \
                                 "a.actor_user_id IN (:anybody))" : "AND false")
      end
      parts << doer_clause("a.actor_user_id", "a.actor_kind")
      parts << "AND a.occurred_at >= :after" if from_at
      parts << "AND a.occurred_at < :before" if upto_at
      parts.compact.join("\n")
    end

    def slack_where
      parts = []
      parts << "AND e.actor_id IN (:actors)" if search.of("actor").any?
      parts << "AND e.entity_id IN (:subjects)" if search.of("about").any?
      parts << "AND e.action IN (:actions)" if search.of("action").any?
      parts << "AND e.channel_id IN (:channels)" if search.of("channel").any?
      parts << "AND e.category IN (:categories)" if search.of("category").any?
      parts << "AND #{SLACK_SEARCHED} @@ websearch_to_tsquery('simple', :text)" if search.text?
      parts << ip_clause("e") if search.of("ip").any?
      parts << email_clause if search.of("ip").empty? && looked_up?
      parts << "AND false" if search.one("is") == "nemo"
      parts << "AND e.at >= :after" if from_at
      parts << "AND e.at < :before" if upto_at
      parts.compact.join("\n")
    end

    def slack_view_where
      parts = []
      parts << "AND a.action IN (:actions)" if search.of("action").any?
      parts << "AND v.actor_id IN (:actors)" if search.of("actor").any?
      parts << "AND v.object_id IN (:subjects)" if search.of("about").any?
      parts << "AND v.object_id IN (:channels)" if search.of("channel").any?
      parts << "AND a.action IN (:category_actions)" if search.of("category").any?
      parts << "AND #{SLACK_VIEW_SEARCHED} @@ websearch_to_tsquery('simple', :text)" if search.text?
      parts << ip_clause("v") if search.of("ip").any?
      if looked_up? && search.of("ip").empty?
        parts << (anybody.any? ? "AND v.actor_id IN (:anybody)" : "AND false")
      end
      parts << "AND false" if search.one("is") == "nemo"
      parts << "AND v.at >= :after" if from_at
      parts << "AND v.at < :before" if upto_at
      parts.join("\n")
    end

    def view_actions
      @view_actions ||= ApplicationRecord.connection.select_values(VIEW_ACTIONS)
    end

    def high_volume? = search.one("show") == "high_volume"

    def slack_views? = high_volume? || search.of("action").intersect?(view_actions)

    EMAIL_FIELDS = %w[e.actor_email e.entity_email].freeze

    def email_clause
      held = []
      search.of("email").each_with_index do |_said, at|
        held.concat(EMAIL_FIELDS.map { |field| "#{field} = :email_#{at}" })
      end
      search.of("domain").each_with_index do |_said, at|
        held.concat(EMAIL_FIELDS.map { |field| "split_part(#{field}, '@', 2) = :domain_#{at}" })
      end
      held << "e.actor_id IN (:anybody)" if anybody.any?
      held.empty? ? "AND false" : "AND (#{held.join(' OR ')})"
    end

    def ip_clause(table)
      held = search.of("ip").map { |term_value|
        operator = term_value.include?("/") ? "<<" : "="
        "#{table}.ip #{operator} :ip_#{term_value.hash.abs}::inet"
      }
      seen = anybody.any? ? " OR #{table}.actor_id IN (:anybody)" : ""
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
      parts << "AND false" if search.of("category").any?
      parts << "AND false" if search.text?
      parts << "AND false" if search.of("ip").any?
      if looked_up? && search.of("ip").empty?
        parts << (anybody.any? ? "AND (l.subject_user_id IN (:anybody) OR " \
                                 "l.actor_id IN (:anybody))" : "AND false")
      end
      parts << "AND false" if search.one("is") == "nemo"
      parts << "AND l.looked_at >= :after" if from_at
      parts << "AND l.looked_at < :before" if upto_at
      parts.compact.join("\n")
    end

    def branches
      held = []
      if wanted_sources.include?(FIRE_ENGINE)
        held << ENGINE_BRANCH.sub("ENGINE_WHERE", engine_where)
      end
      if wanted_sources.include?(SLACK)
        held << SLACK_BRANCH.sub("SLACK_WHERE", slack_where)
        held << SLACK_VIEW_BRANCH.sub("SLACK_VIEW_WHERE", slack_view_where) if slack_views?
      end
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

    RISING = "(at, id) > (:after_at::timestamptz, :after_id)".freeze

    def paged_rows
      return ask(page_sql).map { |row| build(row) } if after_at.nil?

      found = ask("#{body(RISING)} ORDER BY at, id LIMIT #{LIMIT + 1}").map { |row| build(row) }
      return found.first(LIMIT).reverse if found.size > LIMIT

      @top = true
      ask("#{body} ORDER BY at DESC, id DESC LIMIT #{LIMIT}").map { |row| build(row) }
    end

    def first_page?
      rows
      @top || (after_at.nil? && before_at.nil?)
    end

    def before_at
      return (jump_on + 1).in_time_zone.beginning_of_day if jump_on && @params["before_at"].blank?

      stamp(@params["before_at"])
    end

    def after_at
      return nil if @params["before_at"].present? || jump_on

      stamp(@params["after_at"])
    end

    def after_id = @params["after_id"].to_s.presence

    def stamp(value)
      held = value.to_s.presence
      held && Time.zone.parse(held)
    rescue ArgumentError
      nil
    end

    def before_id = @params["before_id"].to_s.presence

    def page_sql
      "#{body(keyset)} ORDER BY at DESC, id DESC LIMIT #{LIMIT}"
    end

    def histogram_sql
      "SELECT date_trunc(:unit, at AT TIME ZONE :zone)::text AS bin, count(*) AS found " \
        "FROM (#{body(HISTOGRAM_WINDOW)}) held GROUP BY 1"
    end

    def count_sql
      capped = body(capped: true, pick: COUNTING_PICK)
      "SELECT count(*) AS found FROM (#{capped} LIMIT #{COUNT_CEILING + 1}) counted"
    end

    def binds
      held = {
        since: since, text: search.text, before_at: before_at, before_id: before_id,
        after_at: after_at, after_id: after_id,
        wanted_kept: !refusals?,
        actors: search.of("actor").presence || [""],
        subjects: search.of("about").presence || [""],
        actions: search.of("action").presence || [""],
        channels: search.of("channel").presence || [""],
        categories: search.of("category").presence || [""],
        category_actions: AuditCatalogue.actions_in(search.of("category")).presence || [""],
        anybody: anybody.presence || [""],
        after: from_at, before: upto_at
      }
      search.of("ip").each { |term_value| held[:"ip_#{term_value.hash.abs}"] = term_value }
      search.of("email").each_with_index { |term_value, at| held[:"email_#{at}"] = term_value.downcase }
      search.of("domain").each_with_index { |term_value, at| held[:"domain_#{at}"] = term_value.downcase }
      held
    end

    def day_start(value)
      value && Time.zone.parse(value)
    end

    def from_at
      return @from_at if defined?(@from_at)

      @from_at = [day_start(search.one("after")), search.since].compact.max
    end

    def upto_at
      return @upto_at if defined?(@upto_at)

      @upto_at = day_start(search.one("before"))
    end

    def ask(sql, extra = {})
      ApplicationRecord.connection.select_all(ApplicationRecord.sanitize_sql([sql, binds.merge(extra)]))
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
      when SLACK then "#{SLACK_BRANCH.sub('SLACK_WHERE', 'AND e.id::text = :id')}\n" \
                      "UNION ALL\n#{SLACK_VIEW_BRANCH.sub('SLACK_VIEW_WHERE', 'AND v.id::text = :id')}"
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
        subject_id: row["subject_id"], before: shown(held_json(row["before"])),
        after: shown(held_json(row["after"])), detail: shown(held_json(row["detail"]))
      )
    end

    IDENTITY_KEY = /email|ip_address/
    ADDRESS_SHAPE = /\A[0-9a-f.:]{3,45}\z/i
    HIDDEN = "hidden".freeze

    def shown(value)
      return value if identity?

      scrubbed(value)
    end

    def scrubbed(value)
      case value
      when Hash
        value.reject { |key, _| key.to_s.match?(IDENTITY_KEY) }.transform_values { |one| scrubbed(one) }
      when Array then value.map { |one| scrubbed(one) }
      when String then identity_value?(value) ? HIDDEN : value
      else value
      end
    end

    def identity_value?(value)
      return true if value.match?(AuditSearch::EMAIL)
      return false unless value.match?(ADDRESS_SHAPE)

      IPAddr.new(value)
      true
    rescue IPAddr::Error
      false
    end
  end
end
