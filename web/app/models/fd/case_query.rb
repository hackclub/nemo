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
      "opened" => "opened", "resolved" => "resolved",
      "case" => "case number", "actions" => "action count"
    }.freeze
    DIRS = %w[asc desc].freeze
    ASSIGNEE = { "anyone" => "anyone", "me" => "me", "nobody" => "nobody" }.freeze

    AGE_WARN = 2.days
    AGE_CRIT = 5.days
    AGE_DAYS = { "2d" => 2, "5d" => 5 }.freeze
    AGE_WORDS = { "2d" => "older than two days", "5d" => "older than five days" }.freeze

    VIEWS = {
      "attention" => "Open",
      "unassigned" => "Unassigned",
      "mine" => "Mine",
      "acted" => "With actions",
      "aging" => "Over 5d",
      "resolved" => "Resolved",
      "everything" => "Everything"
    }.freeze

    TABS = %w[attention unassigned mine acted resolved everything].freeze

    VIEW_FACETS = {
      "attention" => { "status" => "open" },
      "mine" => { "status" => "open", "assignee" => "me" },
      "unassigned" => { "status" => "open", "assignee" => "nobody" },
      "acted" => { "status" => "open", "actions" => "some" },
      "aging" => { "status" => "open", "age" => "5d" },
      "resolved" => { "status" => "resolved", "sort" => "resolved" },
      "everything" => {}
    }.freeze

    RESOLVED = {
      "any" => "any time", "month" => "this month",
      "quarter" => "this quarter", "year" => "this year"
    }.freeze

    DEFAULTS = {
      "status" => "any", "age" => "any", "assignee" => "anyone", "category" => "any", "tag" => "any",
      "subject" => "anyone", "actions" => "any", "opened" => "any", "resolved" => "any",
      "sort" => "opened", "dir" => "desc"
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
      FACET_KEYS.excluding("sort", "dir").any? { |key| !default?(key) }
    end

    def view
      raw = @params["view"].to_s
      return nil if raw == NO_VIEW || filter_facets.any?

      VIEWS.key?(raw) ? raw : DEFAULT_VIEW
    end

    def view_label = VIEWS.fetch(view)

    def views
      counts = self.class.view_counts(viewer)
      VIEWS.map do |key, label|
        View.new(key: key, label: label, count: counts.fetch(key), current: key == view)
      end
    end

    COUNTS_SQL = <<~SQL.freeze
      SELECT
        count(*) FILTER (WHERE c.resolved_at IS NULL) AS attention,
        count(*) FILTER (
          WHERE c.resolved_at IS NULL AND (:viewer IS NULL OR EXISTS (
            SELECT 1 FROM fd.case_assignees a
            WHERE a.case_id = c.id AND a.user_id = :viewer
          ))
        ) AS mine,
        count(*) FILTER (
          WHERE c.resolved_at IS NULL AND NOT EXISTS (
            SELECT 1 FROM fd.case_assignees a WHERE a.case_id = c.id
          )
        ) AS unassigned,
        count(*) FILTER (
          WHERE c.resolved_at IS NULL AND EXISTS (
            SELECT 1 FROM fd.actions a WHERE a.case_id = c.id
          )
        ) AS acted,
        count(*) FILTER (WHERE c.resolved_at IS NULL AND c.opened_at <= :aging) AS aging,
        count(*) FILTER (
          WHERE c.resolved_at IS NOT NULL AND c.duplicate_of IS NULL
        ) AS resolved,
        count(*) AS everything
      FROM fd.cases c
    SQL

    def self.view_counts(viewer, now: Time.current)
      binds = { viewer: viewer.presence, aging: now - AGE_CRIT, month: now.beginning_of_month }
      row = Case.connection.select_one(Case.sanitize_sql([COUNTS_SQL, binds]))

      VIEWS.keys.index_with { |key| row[key].to_i }
    end

    def to_params
      return order_params if view == DEFAULT_VIEW
      return { "view" => view }.merge(order_params) if view

      (filter_facets.presence || { "view" => NO_VIEW }).merge(order_params)
    end

    def order_params
      selected_facets.slice(*ORDER_KEYS)
    end

    def reordered_params(dir)
      params = to_params.except(*ORDER_KEYS)
      dir == DEFAULTS["dir"] ? params : params.merge("dir" => dir)
    end

    def facet_params(overrides)
      base = view ? VIEW_FACETS.fetch(view) : selected_facets
      selected = base.merge(overrides.stringify_keys)
        .reject { |key, value| value.to_s == DEFAULTS[key] || value.blank? }

      selected.presence || { "view" => NO_VIEW }
    end

    def sorting?(key)
      self["sort"] == key
    end

    def descending?
      self["dir"] == "desc"
    end

    def sort_params(key)
      return facet_params("sort" => key, "dir" => DEFAULTS["dir"]) unless sorting?(key)
      return facet_params("dir" => "asc") if descending?

      facet_params("sort" => DEFAULTS["sort"], "dir" => DEFAULTS["dir"])
    end

    def relation
      scope = apply_sort(apply_view(Case.all))
      scope = apply_status(scope)
      scope = apply_age(scope)
      scope = apply_assignee(scope)
      scope = apply_category(scope)
      scope = apply_tag(scope)
      scope = apply_subject(scope)
      scope = apply_actions(scope)
      apply_resolved(apply_opened(scope))
    end

    def title
      return view_label if view

      phrases = [age_phrase, assignee_phrase, category_phrase, tag_phrase, subject_phrase,
                 actions_phrase, opened_phrase, resolved_phrase].compact
      return status_lead if phrases.empty?
      return tag_phrase if phrases == [tag_phrase] && default?("status")

      "#{status_lead}, #{phrases.to_sentence}"
    end

    def summary(visible_count, total)
      ["#{visible_count} of #{total}", SORT.fetch(self["sort"])].join(" · ")
    end

    def empty_note
      case view
      when "attention" then "No open cases"
      when "mine" then "No assigned cases"
      when "unassigned" then "No unassigned cases"
      when "aging" then "No cases over 5d"
      when "resolved" then "No resolved cases"
      when "everything" then "No cases"
      else "No matching cases"
      end
    end

    PRIMARY = %w[status age assignee sort].freeze

    def inline_facets
      active = facets.select(&:on)
      active + facets.reject(&:on).select { |facet| PRIMARY.include?(facet.key) }
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
      assignee_ids = CaseAssignee.distinct.order(:user_id).pluck(:user_id)
      ASSIGNEE.merge(assignee_ids.index_with { |id| "@#{id}" })
    end

    def category_options
      { "any" => "any" }.merge(InfractionCategory.labels)
    end

    private

    DEFAULT_VIEW = "attention".freeze
    NO_VIEW = "none".freeze

    ORDER_KEYS = %w[dir].freeze

    def selected_facets
      @selected_facets ||= FACET_KEYS.filter_map { |key|
        raw = @params[key].to_s
        [key, raw] if allowed?(key, raw) && raw != DEFAULTS[key]
      }.to_h
    end

    def filter_facets
      selected_facets.except(*ORDER_KEYS)
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
      when "dir" then DIRS.include?(raw)
      when "category" then raw == "any" || InfractionCategory.known_key?(raw)
      when "tag" then raw == "any" || (raw.length <= Tag::NAME_LENGTH && raw.match?(Tag::NAME_SHAPE))
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
      when "resolved"
        scope.not_duplicate.where.not(resolved_at: nil)
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

    LIVE_ACTION_CATEGORY = <<~SQL.squish
      EXISTS (
        SELECT 1 FROM fd.actions a
        WHERE a.case_id = fd.cases.id AND a.reversed_at IS NULL AND a.category_key = :key
      )
      OR (
        NOT EXISTS (
          SELECT 1 FROM fd.actions a
          WHERE a.case_id = fd.cases.id AND a.reversed_at IS NULL AND a.category_key IS NOT NULL
        )
        AND fd.cases.category_key = :key
      )
    SQL

    CATEGORY_COUNTS = <<~SQL.squish
      WITH action_category AS (
        SELECT DISTINCT a.case_id, a.category_key FROM fd.actions a
        WHERE a.reversed_at IS NULL AND a.category_key IS NOT NULL
      ),
      case_category AS (
        SELECT case_id, category_key FROM action_category
        UNION
        SELECT c.id, c.category_key FROM fd.cases c
        WHERE c.category_key IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM action_category ac WHERE ac.case_id = c.id)
      )
      SELECT category_key, count(*) FROM case_category GROUP BY category_key
    SQL

    def self.category_counts
      Case.connection.select_rows(CATEGORY_COUNTS).to_h { |key, count| [key, count.to_i] }
    end

    def apply_category(scope)
      return scope if default?("category")

      scope.where(LIVE_ACTION_CATEGORY, key: self["category"])
    end

    def apply_tag(scope)
      return scope if default?("tag")

      tagged = CaseTag.where(tag_id: Tag.where(name: self["tag"]).select(:id)).select(:case_id)
      scope.where(id: tagged)
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
      direction = descending? ? "DESC" : "ASC"
      case self["sort"]
      when "case" then scope.order(Arel.sql("fd.cases.id #{direction}"))
      when "actions" then scope.order(Arel.sql(ACTION_COUNT_SQL)).order(:opened_at)
      when "resolved"
        scope.order(Arel.sql("fd.cases.resolved_at #{direction} NULLS LAST"))
          .order(Arel.sql("fd.cases.opened_at #{direction}"))
      else scope.order(Arel.sql("fd.cases.opened_at #{direction}"))
      end
    end

    ACTION_COUNT_SQL =
      "(SELECT count(*) FROM fd.actions WHERE fd.actions.case_id = fd.cases.id) DESC".freeze

    def status_lead
      case self["status"]
      when "open" then "Open"
      when "resolved" then "Resolved"
      else "All cases"
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

    def tag_phrase
      default?("tag") ? nil : "tag:#{self['tag']}"
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
