module Fd
  class JoinerQuery
    IDENTITY_READ = "identity.read".freeze

    Facet = Struct.new(:key, :label, :value, :value_label, :options, :on, :kind,
      keyword_init: true)
    View = Struct.new(:key, :label, :count, :current, keyword_init: true)
    Row = Struct.new(:user_id, :joined_at, :source, :handle, :display_name,
      :avatar_hash, :email, :domain, :domain_people, :in_force, :kinds, :deactivated,
      :seen_app, :seen_country, :seen_people, :real_name, :ip, :region, :isp, :seen_os,
      :raw_agent, :seen_at, keyword_init: true) do
      def deactivated? = deactivated

      def guarded? = in_force.to_i.positive?

      def lone_domain? = domain.present? && domain_people.to_i <= 1

      def seen_from
        [seen_app, seen_country].compact_blank.join(" \u00b7 ").presence
      end

      def crowded? = seen_people.to_i >= CROWDED

      def close_company? = seen_people.to_i.between?(2, CROWDED - 1)

      def name = real_name.presence || display_name.presence || handle.presence

      def client
        [seen_app, seen_os].compact_blank.join(" on ").presence
      end

      def where_from
        [Fd::Countries.name_for(seen_country), isp].compact_blank.join(", ").presence
      end

      def flag = Fd::Countries.flag_for(seen_country)

      def detail? = [email, ip, client, where_from].any?(&:present?)
    end

    CROWDED = 20
    LIMIT = 50
    MIN_TERM = 2

    VIEWS = {
      "newest" => "Newest",
      "guarded" => "Under a guard",
      "gone" => "Deactivated"
    }.freeze

    TABS = %w[newest guarded gone].freeze

    VIEW_FACETS = {
      "newest" => {},
      "guarded" => { "state" => "guarded" },
      "gone" => { "state" => "gone" }
    }.freeze

    WHEN = { "day" => "today", "week" => "past week", "month" => "past month",
             "any" => "any time" }.freeze
    STATE = { "any" => "any", "clean" => "nothing on record", "guarded" => "under a guard",
              "gone" => "deactivated" }.freeze
    SHAPE = { "any" => "any", "lone" => "first on their domain" }.freeze
    SORT = { "joined" => "when they joined", "domain" => "email domain",
             "name" => "name" }.freeze
    DIRS = %w[desc asc].freeze

    DEFAULTS = {
      "when" => "week", "state" => "any", "shape" => "any", "domain" => "any",
      "sort" => "joined", "dir" => "desc"
    }.freeze
    WINDOW_KEY = "when".freeze
    TERM_KEY = "q".freeze
    FACET_KEYS = (DEFAULTS.keys - [WINDOW_KEY]).freeze
    KEYS = (DEFAULTS.keys + %w[view page q]).freeze

    DEFAULT_VIEW = "newest".freeze
    NO_VIEW = "none".freeze

    DOMAIN = /\A[a-z0-9.-]+\.[a-z]{2,}\z/i

    def initialize(params = {}, actor: nil)
      @params = params
      @actor = actor
    end

    attr_reader :actor

    def identity?
      return @identity if defined?(@identity)

      @identity = actor.present? && actor.may?(IDENTITY_READ)
    end

    def [](key)
      raw = @params[key].to_s
      return raw if allowed?(key, raw)
      return DEFAULTS.fetch(key) if key == WINDOW_KEY

      implied.fetch(key) { DEFAULTS.fetch(key) }
    end

    def term
      @term ||= @params[TERM_KEY].to_s.strip.delete_prefix("@")
    end

    def asked? = term.length >= MIN_TERM

    def default?(key) = self[key] == DEFAULTS.fetch(key)

    def filtered?
      FACET_KEYS.excluding("sort", "dir").any? { |key| !default?(key) }
    end

    def view
      raw = @params["view"].to_s
      return nil if raw == NO_VIEW || chosen_facets.any?


      VIEWS.key?(raw) ? raw : DEFAULT_VIEW
    end

    def view_label = VIEWS.fetch(view)

    def views
      counts = view_counts
      VIEWS.map do |key, label|
        View.new(key: key, label: label, count: counts.fetch(key, 0), current: key == view)
      end
    end

    def carried
      held = {}
      held[WINDOW_KEY] = self[WINDOW_KEY] unless default?(WINDOW_KEY)
      held[TERM_KEY] = term if asked?
      held
    end

    def to_params
      carried.merge(placed)
    end

    def view_params(key)
      held = {}
      held[WINDOW_KEY] = self[WINDOW_KEY] unless default?(WINDOW_KEY)
      held[TERM_KEY] = term if asked?
      key == DEFAULT_VIEW ? held : held.merge("view" => key)
    end

    def window_params(key)
      held = placed
      held.delete(TERM_KEY)
      held[TERM_KEY] = term if asked?
      key == DEFAULTS.fetch(WINDOW_KEY) ? held : held.merge(WINDOW_KEY => key)
    end

    def term_params(said)
      held = carried.merge(placed)
      held.delete(TERM_KEY)
      said.present? ? held.merge(TERM_KEY => said) : held
    end

    def facet_params(overrides)
      base = view ? VIEW_FACETS.fetch(view) : chosen_facets
      chosen = base.merge(overrides.stringify_keys)
        .reject { |key, value| value.to_s == DEFAULTS[key] || value.blank? }

      carried.merge(chosen.presence || { "view" => NO_VIEW })
    end

    def page_params(page) = to_params.merge("page" => page)

    def sorting?(key) = self["sort"] == key

    def descending? = self["dir"] == "desc"

    def sort_params(key)
      return facet_params("sort" => key, "dir" => DEFAULTS["dir"]) unless sorting?(key)
      return facet_params("dir" => "asc") if descending?

      facet_params("sort" => DEFAULTS["sort"], "dir" => DEFAULTS["dir"])
    end

    def facets
      [
        facet("state", "Standing", STATE),
        facet("shape", "Shape", SHAPE),
        (facet("domain", "Email domain", { "any" => "any" }, kind: :typed) if identity?),
        facet("sort", "Sort", SORT)
      ].compact
    end

    PRIMARY = %w[when state sort].freeze

    def inline_facets
      shown = facets.select(&:on)
      shown + facets.reject(&:on).select { |facet| PRIMARY.include?(facet.key) }
    end

    def more_facets
      facets.reject { |facet| facet.on || PRIMARY.include?(facet.key) }
    end

    def rows
      @rows ||= ask(page_sql, limit: LIMIT, offset: (page - 1) * LIMIT)
        .map { |row| build(row) }
    end

    def one(user_id)
      said = user_id.to_s.strip
      return nil if said.blank?

      found = ask(body("*", "user_id = :who"), who: said).first
      found && build(found)
    end

    def total
      @total ||= ask(count_sql).first["found"].to_i
    end

    def page
      @page ||= [@params["page"].to_i, 1].max.clamp(1, pages)
    end

    def pages
      @pages ||= [(total / LIMIT.to_f).ceil, 1].max
    end

    def first_shown = ((page - 1) * LIMIT) + 1

    def last_shown = [first_shown + rows.size - 1, total].min

    def title
      return "#{view_label} matching #{term}" if view && asked?
      return view_label if view

      rest = [state_phrase, shape_phrase, domain_phrase, term_phrase].compact
      lead = "Joined #{WHEN.fetch(self[WINDOW_KEY])}"
      rest.empty? ? lead : "#{lead}, #{rest.to_sentence}"
    end

    def summary
      ["#{total.zero? ? 0 : first_shown}–#{last_shown} of #{total}",
       SORT.fetch(self["sort"])].join(" · ")
    end

    def empty_note
      return "Nobody who joined #{WHEN.fetch(self[WINDOW_KEY])} matches #{term}." if asked?

      case view
      when "guarded" then "Nobody who joined lately is under a guard."
      when "gone" then "Nobody who joined lately has been deactivated."
      else "Nobody joined in this window."
      end
    end

    private

    def placed
      return {} if view == DEFAULT_VIEW
      return { "view" => view } if view

      chosen_facets.presence || { "view" => NO_VIEW }
    end

    def chosen_facets
      @chosen_facets ||= FACET_KEYS.filter_map { |key|
        raw = @params[key].to_s
        [key, raw] if allowed?(key, raw) && raw != DEFAULTS[key]
      }.to_h
    end

    def implied
      view ? VIEW_FACETS.fetch(view) : {}
    end

    def facet(key, label, options, kind: :list)
      value = self[key]
      Facet.new(key: key, label: label, value: value,
        value_label: options.fetch(value) { value }, options: options,
        on: !default?(key), kind: kind)
    end

    def allowed?(key, raw)
      return false if raw.blank?

      case key
      when "when" then WHEN.key?(raw)
      when "state" then STATE.key?(raw)
      when "shape" then SHAPE.key?(raw)
      when "sort" then SORT.key?(raw)
      when "dir" then DIRS.include?(raw)
      when "domain" then raw == "any" || (identity? && raw.match?(DOMAIN))
      else false
      end
    end

    IDENTITY_COLUMNS =
      ", mi.email, lower(split_part(mi.email, '@', 2)) AS domain, mi.real_name".freeze
    BLIND_COLUMNS =
      ", NULL::text AS email, NULL::text AS domain, NULL::text AS real_name".freeze

    IDENTITY_JOIN = <<~SQL.freeze
      LEFT JOIN fd.member_identity mi
        ON mi.user_id = j.user_id AND mi.purged_at IS NULL
    SQL

    SEEN_COLUMNS =
      ", seen.ua_app AS seen_app, place.country AS seen_country, " \
      "coalesce(cohort.people, 0) AS seen_people, " \
      "host(seen.ip) AS ip, place.region AS region, place.isp AS isp, " \
      "seen.ua_os AS seen_os, seen.ua AS raw_agent, seen.at AS seen_at".freeze
    BLIND_SEEN =
      ", NULL::text AS seen_app, NULL::text AS seen_country, 0 AS seen_people, " \
      "NULL::text AS ip, NULL::text AS region, NULL::text AS isp, " \
      "NULL::text AS seen_os, NULL::text AS raw_agent, " \
      "NULL::timestamptz AS seen_at".freeze

    SEEN_JOIN = <<~SQL.freeze
      LEFT JOIN LATERAL (
        SELECT l.ua_app, l.ua_os, l.ua, l.country, l.region, l.isp, l.ip, l.ip_prefix, l.at
        FROM fd.login_event l
        WHERE l.user_id = j.user_id
        ORDER BY l.at DESC
        LIMIT 1
      ) seen ON true
      LEFT JOIN LATERAL (
        SELECT l.country, l.region, l.isp
        FROM fd.login_event l
        WHERE l.user_id = j.user_id AND l.country IS NOT NULL
        ORDER BY l.at DESC
        LIMIT 1
      ) place ON true
      LEFT JOIN fd.ip_cohort cohort ON cohort.ip_prefix = seen.ip_prefix
    SQL

    DOMAIN_TALLY = <<~SQL.freeze
      , domains AS (
        SELECT lower(split_part(email, '@', 2)) AS domain, count(*) AS people
        FROM fd.member_identity
        WHERE purged_at IS NULL AND email IS NOT NULL AND email <> ''
        GROUP BY 1
      )
    SQL

    def body(columns, where)
      <<~SQL
        WITH joined AS (
          SELECT j.user_id, j.joined_at, j.source,
                 lag(j.joined_at) OVER w AS before_at,
                 lead(j.joined_at) OVER w AS after_at
          FROM fd.member_joins j
          WHERE #{window_clause}
          WINDOW w AS (PARTITION BY (j.source = 'team_join') ORDER BY j.joined_at)
        )#{identity? ? DOMAIN_TALLY : ''}
        , picked AS (
          SELECT j.user_id, j.joined_at, j.source,
                 m.handle, m.display_name, m.avatar_hash
                 #{identity? ? IDENTITY_COLUMNS : BLIND_COLUMNS},
                 #{identity? ? 'coalesce(d.people, 0)' : '0'} AS domain_people,
                 (SELECT count(*) FROM fd.member_guards g
                   WHERE g.subject_id = j.user_id AND g.state IN ('live', 'lifting')
                 ) AS in_force,
                 (SELECT string_agg(DISTINCT g.kind, ',') FROM fd.member_guards g
                   WHERE g.subject_id = j.user_id AND g.state IN ('live', 'lifting')
                 ) AS kinds,
                 EXISTS (SELECT 1 FROM fd.member_guards g
                   WHERE g.subject_id = j.user_id AND g.kind = 'deactivation'
                     AND g.state IN ('live', 'lifting')
                 ) AS deactivated
                 #{identity? ? SEEN_COLUMNS : BLIND_SEEN}
          FROM joined j
          JOIN fd.member m ON m.user_id = j.user_id AND NOT m.is_bot
          #{identity? ? IDENTITY_JOIN : ''}
          #{identity? ? 'LEFT JOIN domains d ON d.domain = lower(split_part(mi.email, \'@\', 2))' : ''}
          #{identity? ? SEEN_JOIN : ''}
        )
        SELECT #{columns} FROM picked WHERE #{where}
      SQL
    end

    def page_sql
      "#{body('*', picked_clause)} ORDER BY #{order} LIMIT :limit OFFSET :offset"
    end

    def count_sql
      body("count(*) AS found", picked_clause)
    end

    WINDOWS = { "day" => 1, "week" => 7, "month" => 30 }.freeze

    def window_clause
      days = WINDOWS[self["when"]]
      days ? "j.joined_at >= now() - make_interval(days => #{days})" : "true"
    end

    def picked_clause
      parts = ["true"]
      parts << "domain IS NOT NULL AND domain_people <= 1" if self["shape"] == "lone"
      parts << "in_force = 0 AND NOT deactivated" if self["state"] == "clean"
      parts << "in_force > 0" if self["state"] == "guarded"
      parts << "deactivated" if self["state"] == "gone"
      parts << "domain = :domain" unless default?("domain")
      parts << term_clause if asked?
      parts.join(" AND ")
    end

    TERM_FIELDS = %w[handle display_name].freeze
    IDENTITY_TERM_FIELDS = %w[email].freeze

    def term_fields
      identity? ? TERM_FIELDS + IDENTITY_TERM_FIELDS : TERM_FIELDS
    end

    def term_clause
      said = term_fields.map { |field| "lower(#{field}) LIKE :term" }
      "(user_id = :id OR #{said.join(' OR ')})"
    end

    def order
      way = descending? ? "DESC" : "ASC"
      tie = descending? ? "ASC" : "DESC"

      case self["sort"]
      when "domain" then "domain #{way} NULLS LAST, joined_at DESC"
      when "name"
        "lower(coalesce(nullif(display_name, ''), nullif(handle, ''), user_id)) #{way}, " \
          "user_id #{tie}"
      else "joined_at #{way}, user_id #{tie}"
      end
    end

    def binds
      { domain: self["domain"].downcase, id: term.upcase,
        term: "%#{ApplicationRecord.sanitize_sql_like(term.downcase)}%" }
    end

    def ask(sql, extra = {})
      ApplicationRecord.connection.select_all(
        ApplicationRecord.sanitize_sql([sql, binds.merge(extra)])
      )
    end

    def build(row)
      Row.new(
        user_id: row["user_id"], joined_at: row["joined_at"], source: row["source"],
        handle: row["handle"],
        display_name: row["display_name"], avatar_hash: row["avatar_hash"],
        email: row["email"], domain: row["domain"],
        domain_people: row["domain_people"].to_i, in_force: row["in_force"].to_i,
        kinds: row["kinds"].to_s.split(","), deactivated: row["deactivated"],
        seen_app: row["seen_app"], seen_country: row["seen_country"],
        seen_people: row["seen_people"].to_i, real_name: row["real_name"],
        ip: row["ip"], region: row["region"], isp: row["isp"],
        seen_os: row["seen_os"], raw_agent: row["raw_agent"], seen_at: row["seen_at"]
      )
    end

    def counted
      "count(*) AS newest, " \
        "count(*) FILTER (WHERE in_force > 0) AS guarded, " \
        "count(*) FILTER (WHERE deactivated) AS gone"
    end

    def view_counts
      @view_counts ||= begin
        row = ApplicationRecord.connection.select_one(
          ApplicationRecord.sanitize_sql([body(counted, "true"), binds])
        )
        VIEWS.keys.index_with { |key| row[key].to_i }
      end
    end

    def state_phrase
      case self["state"]
      when "clean" then "with nothing on record"
      when "guarded" then "under a guard"
      when "gone" then "deactivated"
      end
    end

    def shape_phrase
      case self["shape"]
      when "lone" then "first on their email domain"
      end
    end

    def domain_phrase
      default?("domain") ? nil : "on #{self['domain']}"
    end

    def term_phrase
      asked? ? "matching #{term}" : nil
    end
  end
end
