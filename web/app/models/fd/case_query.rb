module Fd
  class CaseQuery
    Facet = Struct.new(:key, :label, :value, :value_label, :options, :on, :kind,
      keyword_init: true)

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

    AGE_DAYS = { "2d" => 2, "5d" => 5 }.freeze
    AGE_WORDS = { "2d" => "older than two days", "5d" => "older than five days" }.freeze

    DEFAULTS = {
      "status" => "open", "age" => "any", "assignee" => "anyone", "category" => "any",
      "subject" => "anyone", "actions" => "any", "opened" => "any", "sort" => "oldest"
    }.freeze
    KEYS = DEFAULTS.keys.freeze

    def initialize(params = {}, viewer: nil)
      @params = params
      @viewer = viewer
    end

    attr_reader :viewer

    def [](key)
      raw = @params[key].to_s
      allowed?(key, raw) ? raw : DEFAULTS.fetch(key)
    end

    def default?(key)
      self[key] == DEFAULTS.fetch(key)
    end

    def filtered?
      KEYS.excluding("sort").any? { |key| !default?(key) }
    end

    def to_params(overrides = {})
      chosen = KEYS.index_with { |key| self[key] }.merge(overrides.stringify_keys)
      chosen.reject { |key, value| value.to_s == DEFAULTS[key] || value.blank? }
    end

    def relation
      scope = apply_sort(Case.all)
      scope = apply_status(scope)
      scope = apply_age(scope)
      scope = apply_assignee(scope)
      scope = apply_category(scope)
      scope = apply_subject(scope)
      scope = apply_actions(scope)
      apply_opened(scope)
    end

    def title
      rest = [age_phrase, assignee_phrase, category_phrase, subject_phrase,
              actions_phrase, opened_phrase].compact
      return status_phrase if rest.empty?

      "#{status_phrase}, #{rest.to_sentence}"
    end

    def summary(shown, total)
      ["#{shown} of #{total}", SORT.fetch(self["sort"]),
       "subject context from the warehouse"].join(" · ")
    end

    def empty_note
      return "Nothing open right now." if !filtered? && self["status"] == "open"

      "No case matches this. Clear a filter to widen it."
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
      when "sort" then SORT.key?(raw)
      when "category" then raw == "any" || Case::CATEGORIES.include?(raw)
      when "assignee" then ASSIGNEE.key?(raw) || raw.match?(MEMBER_ID)
      when "subject" then raw == "anyone" || raw.match?(MEMBER_ID)
      else false
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
      since = case self["opened"]
      when "month" then Time.current.beginning_of_month
      when "quarter" then Time.current.beginning_of_quarter
      when "year" then Time.current.beginning_of_year
      end
      since ? scope.where(opened_at: since..) : scope
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

    def status_phrase
      case self["status"]
      when "open" then "Open"
      when "resolved" then "Resolved"
      else "Every case"
      end
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
