module Fd
  class CaseQuery
    Facet = Struct.new(:key, :label, :value, :value_label, :options, :on, :kind,
      keyword_init: true)
    View = Struct.new(:key, :label, :count, :current, keyword_init: true)

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    STATUS = { "open" => "open", "resolved" => "resolved", "any" => "any" }.freeze
    AGE = { "any" => "any", "2d" => "over 2d", "5d" => "over 5d" }.freeze
    ACTIONS = { "any" => "any", "none" => "none logged", "some" => "some logged" }.freeze
    OPENED = {
      "any" => "any time", "month" => "this month",
      "quarter" => "this quarter", "year" => "this year"
    }.freeze
    SORT = {
      "oldest" => "oldest first", "newest" => "newest first", "actions" => "most actions"
    }.freeze
    ASSIGNEE = { "anyone" => "anyone", "me" => "me", "nobody" => "nobody" }.freeze

    AGE_WARN = 2.days
    AGE_CRIT = 5.days
    AGE_DAYS = { "2d" => 2, "5d" => 5 }.freeze
    AGE_WORDS = { "2d" => "older than two days", "5d" => "older than five days" }.freeze

    VIEWS = {
      "attention" => "Needs attention",
      "mine" => "Mine",
      "unassigned" => "Unassigned",
      "aging" => "Aging over 5d",
      "resolved" => "Resolved this month",
      "everything" => "Everything"
    }.freeze

    VIEW_FACETS = {
      "attention" => { "status" => "open" },
      "mine" => { "status" => "open", "assignee" => "me" },
      "unassigned" => { "status" => "open", "assignee" => "nobody" },
      "aging" => { "status" => "open", "age" => "5d" },
      "resolved" => { "status" => "resolved", "resolved" => "month" },
      "everything" => { "sort" => "newest" }
    }.freeze

    RESOLVED = {
      "any" => "any time", "month" => "this month",
      "quarter" => "this quarter", "year" => "this year"
    }.freeze

    DEFAULTS = {
      "status" => "any", "age" => "any", "assignee" => "anyone", "category" => "any",
      "subject" => "anyone", "actions" => "any", "opened" => "any", "resolved" => "any",
      "sort" => "oldest"
    }.freeze
    FACET_KEYS = DEFAULTS.keys.freeze
    KEYS = (FACET_KEYS + ["view"]).freeze

    def initialize(params = {}, viewer: nil)
      @params = params
      @viewer = viewer
    end

    attr_reader :viewer

    def [](key)
      raw = @params[key].to_s
      return raw if allowed?(key, raw)

      implied.fetch(key) { DEFAULTS.fetch(key) }
    end

    def default?(key)
      self[key] == DEFAULTS.fetch(key)
    end

    def filtered?
      FACET_KEYS.excluding("sort").any? { |key| !default?(key) }
    end

    def view
      raw = @params["view"].to_s
      return nil if raw == NO_VIEW || chosen_facets.any?

      VIEWS.key?(raw) ? raw : DEFAULT_VIEW
    end

    def view_label = VIEWS.fetch(view)

    def views
      counts = self.class.view_counts(viewer)
      VIEWS.map do |key, label|
        View.new(key: key, label: label, count: counts.fetch(key), current: key == view)
      end
    end

    def self.view_counts(viewer)
      VIEWS.keys.index_with { |key| new({ "view" => key }, viewer: viewer).relation.count }
    end

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

    def relation
      scope = apply_sort(apply_view(Case.all))
      scope = apply_status(scope)
      scope = apply_age(scope)
      scope = apply_assignee(scope)
      scope = apply_category(scope)
      scope = apply_subject(scope)
      scope = apply_actions(scope)
      apply_resolved(apply_opened(scope))
    end

    def title
      return view_label if view

      rest = [age_phrase, assignee_phrase, category_phrase, subject_phrase,
              actions_phrase, opened_phrase, resolved_phrase].compact
      return status_lead if rest.empty?

      "#{status_lead}, #{rest.to_sentence}"
    end

    def summary(shown, total)
      ["#{shown} of #{total}", SORT.fetch(self["sort"])].join(" · ")
    end

    def empty_note
      case view
      when "attention" then "Nothing needs attention right now."
      when "mine" then "Nothing is assigned to you."
      when "unassigned" then "Nothing unassigned."
      when "aging" then "Nothing open has been sitting for five days."
      when "resolved" then "Nothing has been resolved this month yet."
      when "everything" then "n/a"
      else "No case matches this."
      end
    end

    PRIMARY = %w[status age assignee sort].freeze

    def inline_facets
      shown = facets.select(&:on)
      shown + facets.reject(&:on).select { |facet| PRIMARY.include?(facet.key) }
    end

    def more_facets
      facets.reject { |facet| facet.on || PRIMARY.include?(facet.key) }
    end

    def facets
      [
        facet("status", "Status", STATUS),
        facet("age", "Age", AGE),
        facet("assignee", "Assignee", assignee_options),
        facet("category", "Category", category_options),
        facet("subject", "Subject", { "anyone" => "anyone" }, kind: :typed),
        facet("actions", "Actions", ACTIONS),
        facet("opened", "Opened", OPENED),
        facet("resolved", "Resolved", RESOLVED),
        facet("sort", "Sort", SORT)
      ]
    end

    def assignee_options
      taken = CaseAssignee.distinct.order(:user_id).pluck(:user_id)
      ASSIGNEE.merge(taken.index_with { |id| "@#{id}" })
    end

    def category_options
      { "any" => "any" }.merge(Case::CATEGORIES.index_with { |key| Case.category_label(key) })
    end

    private

    DEFAULT_VIEW = "attention".freeze
    NO_VIEW = "none".freeze

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
      Facet.new(
        key: key, label: label, value: value,
        value_label: options.fetch(value) { value.start_with?("U", "W") ? "@#{value}" : value },
        options: options, on: !default?(key), kind: kind
      )
    end

    def allowed?(key, raw)
      return false if raw.blank?

      case key
      when "status" then STATUS.key?(raw)
      when "age" then AGE.key?(raw)
      when "actions" then ACTIONS.key?(raw)
      when "opened" then OPENED.key?(raw)
      when "resolved" then RESOLVED.key?(raw)
      when "sort" then SORT.key?(raw)
      when "category" then raw == "any" || Case::CATEGORIES.include?(raw)
      when "assignee" then ASSIGNEE.key?(raw) || raw.match?(MEMBER_ID)
      when "subject" then raw == "anyone" || raw.match?(MEMBER_ID)
      else false
      end
    end

    def apply_view(scope)
      case view
      when "attention" then scope.unresolved
      when "mine" then viewer ? scope.unresolved.assigned_to(viewer) : scope.unresolved
      when "unassigned" then scope.unresolved.unassigned
      when "aging" then scope.unresolved.where(opened_at: ..AGE_CRIT.ago)
      when "resolved" then scope.where(resolved_at: Time.current.beginning_of_month..)
      else scope
      end
    end

    def apply_status(scope)
      case self["status"]
      when "open" then scope.unresolved
      when "resolved" then scope.where.not(resolved_at: nil)
      else scope
      end
    end

    def apply_age(scope)
      days = AGE_DAYS[self["age"]]
      days ? scope.where(opened_at: ..days.days.ago) : scope
    end

    def apply_assignee(scope)
      case self["assignee"]
      when "anyone" then scope
      when "nobody" then scope.unassigned
      when "me" then viewer ? scope.assigned_to(viewer) : scope
      else scope.assigned_to(self["assignee"])
      end
    end

    def apply_category(scope)
      default?("category") ? scope : scope.where(category_key: self["category"])
    end

    def apply_subject(scope)
      default?("subject") ? scope : scope.with_subject(self["subject"])
    end

    def apply_actions(scope)
      case self["actions"]
      when "none" then scope.where.not(id: Action.select(:case_id))
      when "some" then scope.where(id: Action.select(:case_id))
      else scope
      end
    end

    def apply_opened(scope)
      since = window(self["opened"])
      since ? scope.where(opened_at: since..) : scope
    end

    def apply_resolved(scope)
      since = window(self["resolved"])
      since ? scope.where(resolved_at: since..) : scope
    end

    def window(value)
      case value
      when "month" then Time.current.beginning_of_month
      when "quarter" then Time.current.beginning_of_quarter
      when "year" then Time.current.beginning_of_year
      end
    end

    def apply_sort(scope)
      case self["sort"]
      when "newest" then scope.newest_first
      when "actions" then scope.order(Arel.sql(ACTION_COUNT_SQL)).order(:opened_at)
      else scope.oldest_first
      end
    end

    ACTION_COUNT_SQL =
      "(SELECT count(*) FROM fd.actions WHERE fd.actions.case_id = fd.cases.id) DESC".freeze

    def status_lead
      case self["status"]
      when "open" then "Open"
      when "resolved" then "Resolved"
      else "Every case"
      end
    end

    def resolved_phrase
      default?("resolved") ? nil : "resolved #{RESOLVED.fetch(self['resolved'])}"
    end

    def age_phrase = AGE_WORDS[self["age"]]

    def assignee_phrase
      case self["assignee"]
      when "anyone" then nil
      when "nobody" then "unassigned"
      when "me" then "assigned to you"
      else "assigned to @#{self['assignee']}"
      end
    end

    def category_phrase
      default?("category") ? nil : Case.category_label(self["category"]).downcase
    end

    def subject_phrase
      default?("subject") ? nil : "about @#{self['subject']}"
    end

    def actions_phrase
      case self["actions"]
      when "none" then "with no action logged"
      when "some" then "with an action logged"
      end
    end

    def opened_phrase
      default?("opened") ? nil : "opened #{OPENED.fetch(self['opened'])}"
    end
  end
end
