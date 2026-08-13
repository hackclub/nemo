module Fd
  class MemberQuery
    Facet = Struct.new(:key, :label, :value, :value_label, :options, :on, keyword_init: true)
    View = Struct.new(:key, :label, :count, :current, keyword_init: true)
    Row = Struct.new(:user_id, :subject_of, :logged_in, :open_cases, :actions, :notes,
      :priors, :last_case_at, keyword_init: true)

    VIEWS = {
      "history" => "Has a history",
      "open" => "Open case",
      "priors" => "Two or more priors",
      "notes" => "Standing notes",
      "everyone" => "Everyone"
    }.freeze

    VIEW_FACETS = {
      "history" => {},
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
    SORT = { "recent" => "most recent case", "cases" => "most cases",
             "actions" => "most actions", "name" => "name" }.freeze

    DEFAULTS = {
      "who" => "history", "priors" => "any", "tenure" => "any", "active" => "any",
      "category" => "any", "state" => "any", "sort" => "recent"
    }.freeze
    FACET_KEYS = DEFAULTS.keys.freeze
    KEYS = (FACET_KEYS + ["view"]).freeze
    PRIMARY = %w[priors tenure active sort].freeze

    LIMIT = 50
    DEFAULT_VIEW = "history".freeze
    NO_VIEW = "none".freeze

    def initialize(params = {})
      @params = params
    end

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
      return {} if view == DEFAULT_VIEW
      return { "view" => view } if view

      chosen_facets.presence || { "view" => NO_VIEW }
    end

    def facet_params(overrides)
      base = view ? VIEW_FACETS.fetch(view) : chosen_facets
      chosen = base.merge(overrides.stringify_keys)
        .reject { |key, value| value.to_s == DEFAULTS[key] || value.blank? }

      chosen.presence || { "view" => NO_VIEW }
    end

    def rows
      @rows ||= narrowed.slice((page - 1) * LIMIT, LIMIT) || []
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
      @total ||= narrowed.size
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
      VIEWS.keys.index_with { |key| new({ "view" => key }).total }
    end

    def summary_rows
      summaries.values
    end

    def self.headline
      seen = new({}).summary_rows
      {
        history: seen.count { |row| row.subject_of.positive? || row.logged_in.positive? },
        priors: seen.count { |row| row.priors >= 2 },
        open: seen.count { |row| row.open_cases.positive? },
        notes: seen.count { |row| row.notes.positive? },
        logged_only: seen.count { |row| row.logged_in.positive? && row.subject_of.zero? }
      }
    end

    def facets
      [
        facet("priors", "Priors", PRIORS),
        facet("tenure", "Tenure", TENURE),
        facet("active", "Last active", ACTIVE),
        facet("sort", "Sort", SORT),
        facet("state", "State", STATE),
        facet("category", "Category", category_options),
        facet("who", "Who", WHO)
      ]
    end

    def inline_facets
      shown = facets.select(&:on)
      shown + facets.reject(&:on).select { |facet| PRIMARY.include?(facet.key) }
    end

    def more_facets
      facets.reject { |facet| facet.on || PRIMARY.include?(facet.key) }
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
      [seen, SORT.fetch(self["sort"])].join(" · ")
    end

    def empty_note
      case view
      when "history" then "Nobody has a conduct history yet."
      when "open" then "Nobody has an open case."
      when "priors" then "Nobody has two or more priors."
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
      when "category" then raw == "any" || Case::CATEGORIES.include?(raw)
      else false
      end
    end

    def narrowed
      @narrowed ||= begin
        found = summaries.values
        found = found.select { |row| row.subject_of.positive? || row.logged_in.positive? } unless
          self["who"] == "everyone"
        found = found.select { |row| row.priors >= self["priors"].to_i } unless default?("priors")
        found = filter_state(found)
        found = filter_context(found)
        sorted(found)
      end
    end

    def filter_state(found)
      case self["state"]
      when "open" then found.select { |row| row.open_cases.positive? }
      when "noted" then found.select { |row| row.notes.positive? }
      when "clean" then found.select { |row| row.subject_of.zero? && row.logged_in.zero? }
      else found
      end
    end

    def filter_context(found)
      return found if default?("tenure") && default?("active")

      context = MemberContext.for(found.map(&:user_id))
      found.select do |row|
        seen = context[row.user_id]
        tenure_ok?(seen) && active_ok?(seen)
      end
    end

    def tenure_ok?(seen)
      return true if default?("tenure")

      days = seen&.tenure_days
      return false if days.nil?

      case self["tenure"]
      when "new" then days < 31
      when "year" then days < 366
      else days >= 366
      end
    end

    def active_ok?(seen)
      return true if default?("active")

      at = seen&.last_active_at
      return self["active"] == "dormant" if at.nil?

      days = (Date.current - at.to_date).to_i
      case self["active"]
      when "week" then days <= 7
      when "month" then days <= 30
      else days > 90
      end
    end

    def sorted(found)
      case self["sort"]
      when "cases" then found.sort_by { |row| [-(row.subject_of + row.logged_in), row.user_id] }
      when "actions" then found.sort_by { |row| [-row.actions, row.user_id] }
      when "name" then found.sort_by { |row| Member.find_by(user_id: row.user_id)&.name.to_s }
      else found.sort_by { |row| [-(row.last_case_at&.to_i || 0), row.user_id] }
      end
    end

    def summaries
      @summaries ||= begin
        found = Hash.new { |all, id| all[id] = Row.new(user_id: id, subject_of: 0, logged_in: 0,
          open_cases: 0, actions: 0, notes: 0, priors: 0) }

        conduct_rows.each do |row|
          held = found[row["user_id"]]
          held.subject_of = row["subject_of"].to_i
          held.logged_in = row["logged_in"].to_i
          held.open_cases = row["open_cases"].to_i
          held.last_case_at = row["last_case_at"]
        end
        Action.group(:target_user_id).count.each { |id, n| found[id].actions = n }
        Note.standing.visible.group(:subject_user_id).count.each { |id, n| found[id].notes = n }
        prior_counts.each { |id, n| found[id].priors = n }

        if self["who"] == "everyone"
          Member.live.pluck(:user_id).each { |id| found[id] }
        end

        found
      end
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

    def conduct_rows
      Case.connection.select_all(Case.sanitize_sql([<<~SQL, { category: self["category"] }]))
        SELECT p.user_id,
               count(*) FILTER (WHERE p.role = 'subject') AS subject_of,
               count(*) FILTER (WHERE p.role <> 'subject') AS logged_in,
               count(*) FILTER (WHERE p.role = 'subject' AND c.resolved_at IS NULL) AS open_cases,
               max(c.opened_at) AS last_case_at
        FROM fd.case_participants p
        JOIN fd.cases c ON c.id = p.case_id
        WHERE (:category = 'any' OR c.category_key = :category)
        GROUP BY p.user_id
      SQL
    end

    def prior_counts
      CaseParticipant.subjects
        .where(case_id: Case.where.not(resolved_at: nil).select(:id))
        .where(<<~SQL.squish)
          EXISTS (
            SELECT 1 FROM fd.actions a
            WHERE a.case_id = fd.case_participants.case_id
              AND a.target_user_id = fd.case_participants.user_id
              AND a.reversed_at IS NULL
          )
        SQL
        .group(:user_id).count
    end
  end
end
