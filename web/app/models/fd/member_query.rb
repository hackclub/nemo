module Fd
  class MemberQuery
    include RosterSql

    Facet = Struct.new(:key, :label, :value, :value_label, :options, :on, keyword_init: true)
    View = Struct.new(:key, :label, :count, :current, keyword_init: true)
    Row = Struct.new(:user_id, :cases, :subject_of, :logged_in, :open_cases, :actions, :in_force,
      :notes, :priors, :last_case_at, keyword_init: true)

    VIEWS = {
      "everyone" => "Everyone",
      "force" => "In force",
      "priors" => "With priors",
      "history" => "Has a history",
      "open" => "Open case",
      "notes" => "Standing notes"
    }.freeze

    TABS = %w[everyone force priors].freeze

    VIEW_FACETS = {
      "history" => { "who" => "history" },
      "force" => { "state" => "force" },
      "open" => { "state" => "open" },
      "priors" => { "priors" => "2" },
      "notes" => { "state" => "noted" },
      "everyone" => { "who" => "everyone" }
    }.freeze

    PRIORS = { "any" => "any", "1" => "1 or more", "2" => "2 or more" }.freeze
    TENURE = { "any" => "any", "new" => "under a month", "year" => "under a year",
               "old" => "over a year" }.freeze
    ACTIVE = { "any" => "any", "week" => "past week", "month" => "past month",
               "dormant" => "not in 90 days" }.freeze
    STATE = { "any" => "any", "open" => "open case", "noted" => "standing notes",
              "clean" => "nothing on record" }.freeze
    WHO = { "history" => "with a history", "everyone" => "everyone" }.freeze
    SORT = { "recent" => "last case", "subject" => "cases as subject",
             "logged" => "cases logged in", "actions" => "actions",
             "notes" => "notes", "name" => "name" }.freeze
    DIRS = %w[desc asc].freeze

    DEFAULTS = {
      "who" => "everyone", "priors" => "any", "tenure" => "any", "active" => "any",
      "category" => "any", "state" => "any", "sort" => "recent", "dir" => "desc"
    }.freeze
    FACET_KEYS = DEFAULTS.keys.freeze
    KEYS = (FACET_KEYS + ["view"]).freeze
    LIMIT = 50
    DEFAULT_VIEW = "everyone".freeze
    NO_VIEW = "none".freeze

    def initialize(params = {})
      @params = params
    end

    def term
      @term ||= @params["q"].to_s.strip.delete_prefix("@")
    end

    def asked? = term.present?

    def [](key)
      raw = @params[key].to_s
      return raw if allowed?(key, raw)

      implied.fetch(key) { DEFAULTS.fetch(key) }
    end

    def default?(key) = self[key] == DEFAULTS.fetch(key)

    def view
      raw = @params["view"].to_s
      return nil if raw == NO_VIEW || chosen_facets.any?

      VIEWS.key?(raw) ? raw : DEFAULT_VIEW
    end

    def view_label = VIEWS.fetch(view)

    def to_params
      asking.merge(picked)
    end

    def picked
      return {} if view == DEFAULT_VIEW
      return { "view" => view } if view

      chosen_facets.presence || { "view" => NO_VIEW }
    end

    def asking = asked? ? { "q" => term } : {}

    def facet_params(overrides)
      base = view ? VIEW_FACETS.fetch(view) : chosen_facets
      chosen = base.merge(overrides.stringify_keys)
        .reject { |key, value| value.to_s == DEFAULTS[key] || value.blank? }

      asking.merge(chosen.presence || { "view" => NO_VIEW })
    end

    def rows
      @rows ||= page_rows
    end

    def page
      @page ||= [@params["page"].to_i, 1].max.clamp(1, pages)
    end

    def pages
      @pages ||= [(total / LIMIT.to_f).ceil, 1].max
    end

    def first_shown
      rows.empty? ? 0 : ((page - 1) * LIMIT) + 1
    end

    def last_shown
      first_shown.zero? ? 0 : first_shown + rows.size - 1
    end

    def page_params(wanted)
      to_params.merge(wanted > 1 ? { "page" => wanted.to_s } : {})
    end

    def total
      @total ||= ask(<<~SQL).first["found"].to_i
        WITH #{aggregates}
        SELECT count(*) AS found FROM roster WHERE #{roster_where}
      SQL
    end

    def population
      @population ||= Member.live.count
    end

    def views
      counts = self.class.view_counts
      VIEWS.map do |key, label|
        View.new(key: key, label: label, count: counts.fetch(key), current: key == view)
      end
    end

    def self.view_counts
      new({}).send(:counts_per_view)
    end

    def summary_rows
      all_rows
    end

    def facets
      [
        facet("priors", "Priors", PRIORS),
        facet("tenure", "Tenure", TENURE),
        facet("active", "Last active", ACTIVE),
        facet("state", "State", STATE),
        facet("category", "Category", category_options)
      ]
    end

    def sorting?(key)
      self["sort"] == key
    end

    def descending?
      self["dir"] == "desc"
    end

    def sort_params(key)
      return facet_params("sort" => key, "dir" => "desc") unless sorting?(key)
      return facet_params("dir" => "asc") if descending?

      facet_params("sort" => DEFAULTS["sort"], "dir" => DEFAULTS["dir"])
    end

    def sort_label
      said = SORT.fetch(self["sort"])
      return "name, a to z" if self["sort"] == "name" && !descending?
      return "name, z to a" if self["sort"] == "name"

      descending? ? "most #{said}" : "least #{said}"
    end

    def title
      return view_label if view

      rest = [priors_phrase, tenure_phrase, active_phrase, state_phrase,
              category_phrase].compact
      lead = self["who"] == "everyone" ? "Everyone" : "With a history"
      rest.empty? ? lead : "#{lead}, #{rest.to_sentence}"
    end

    def summary
      seen = rows.empty? ? "none" : "#{first_shown} to #{last_shown} of #{number_with_delimiter(total)}"
      [seen, sort_label].join(" · ")
    end

    def empty_note
      case view
      when "history" then "Nobody has a conduct history yet."
      when "open" then "Nobody has an open case."
      when "priors" then "Nobody has two or more priors in 12 months."
      when "notes" then "No standing notes on anybody."
      else "No member matches this."
      end
    end

    def category_options
      { "any" => "any" }.merge(Case::CATEGORIES.index_with { |key| Case.category_label(key) })
    end

    private

    def number_with_delimiter(count)
      count.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
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

    def facet(key, label, options)
      value = self[key]
      Facet.new(key: key, label: label, value: value,
        value_label: options.fetch(value, value), options: options, on: !default?(key))
    end

    def allowed?(key, raw)
      return false if raw.blank?

      case key
      when "priors" then PRIORS.key?(raw)
      when "tenure" then TENURE.key?(raw)
      when "active" then ACTIVE.key?(raw)
      when "state" then STATE.key?(raw)
      when "who" then WHO.key?(raw)
      when "sort" then SORT.key?(raw)
      when "dir" then DIRS.include?(raw)
      when "category" then raw == "any" || Case::CATEGORIES.include?(raw)
      else false
      end
    end

    def page_rows
      found = ask(<<~SQL, limit: LIMIT, offset: (page - 1) * LIMIT)
        WITH #{aggregates}
        SELECT * FROM roster WHERE #{roster_where}
        ORDER BY #{roster_order}
        LIMIT :limit OFFSET :offset
      SQL
      found.map { |row| row_from(row) }
    end

    def all_rows
      ask(<<~SQL).map { |row| row_from(row) }
        WITH #{aggregates}
        SELECT * FROM roster WHERE #{roster_where} ORDER BY #{roster_order}
      SQL
    end

    def counts_per_view
      said = VIEWS.keys.map { |key| "count(*) FILTER (WHERE #{view_clause(key)}) AS #{key}" }
      row = ask(<<~SQL).first
        WITH #{aggregates}
        SELECT #{said.join(", ")} FROM roster
      SQL
      VIEWS.keys.index_with { |key| row[key].to_i }
    end

    def view_clause(key)
      case key
      when "history" then "(subject_of > 0 OR logged_in > 0)"
      when "force" then "in_force > 0"
      when "open" then "open_cases > 0"
      when "priors" then "priors >= 2"
      when "notes" then "notes > 0"
      else "1 = 1"
      end
    end

    def row_from(row)
      Row.new(user_id: row["user_id"], cases: row["cases"].to_i,
        subject_of: row["subject_of"].to_i, logged_in: row["logged_in"].to_i,
        open_cases: row["open_cases"].to_i, actions: row["actions"].to_i,
        in_force: row["in_force"].to_i, notes: row["notes"].to_i,
        priors: row["priors"].to_i, last_case_at: row["last_case_at"])
    end

    def priors_phrase
      default?("priors") ? nil : "#{PRIORS.fetch(self['priors'])} priors"
    end

    def tenure_phrase
      default?("tenure") ? nil : "here #{TENURE.fetch(self['tenure'])}"
    end

    def active_phrase
      return nil if default?("active")
      return "not active in 90 days" if self["active"] == "dormant"

      "active in the #{ACTIVE.fetch(self['active']).delete_prefix('past ')}"
    end

    def state_phrase
      case self["state"]
      when "open" then "with an open case"
      when "noted" then "with standing notes"
      when "clean" then "with nothing on record"
      end
    end

    def category_phrase
      default?("category") ? nil : Case.category_label(self["category"]).downcase
    end
  end
end
