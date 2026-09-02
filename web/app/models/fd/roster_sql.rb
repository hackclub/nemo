module Fd
  module RosterSql
    IDENTITY_READ = "identity.read".freeze

    AGGREGATES = <<~SQL
      conduct AS (
        SELECT p.user_id,
               count(DISTINCT p.case_id) AS cases,
               count(*) FILTER (WHERE p.role = 'subject') AS subject_of,
               count(*) FILTER (WHERE p.role <> 'subject') AS logged_in,
               count(*) FILTER (WHERE p.role = 'subject' AND c.resolved_at IS NULL) AS open_cases,
               max(c.opened_at) AS last_case_at
        FROM fd.case_participants p
        JOIN fd.cases c ON c.id = p.case_id
        WHERE (:category = 'any' OR c.category_key = :category)
        GROUP BY p.user_id
      ),
      acted AS (
        SELECT target_user_id AS user_id,
               count(*) AS actions,
               count(*) FILTER (
                 WHERE reversed_at IS NULL AND expires_at > :now
               ) AS in_force,
               count(DISTINCT case_id) FILTER (
                 WHERE reversed_at IS NULL AND performed_at >= :prior_since
               ) AS priors
        FROM fd.actions
        GROUP BY target_user_id
      ),
      noted AS (
        SELECT subject_user_id AS user_id, count(*) AS notes
        FROM fd.notes
        WHERE case_id IS NULL AND subject_user_id IS NOT NULL AND deleted_at IS NULL
        GROUP BY subject_user_id
      ),
      people AS (
        SELECT user_id FROM fd.member WHERE is_deleted = false AND is_bot = false
        UNION SELECT user_id FROM conduct
        UNION SELECT user_id FROM acted
        UNION SELECT user_id FROM noted
      ),
      roster AS (
        SELECT people.user_id,
               coalesce(conduct.cases, 0) AS cases,
               coalesce(conduct.subject_of, 0) AS subject_of,
               coalesce(conduct.logged_in, 0) AS logged_in,
               coalesce(conduct.open_cases, 0) AS open_cases,
               conduct.last_case_at,
               coalesce(acted.actions, 0) AS actions,
               coalesce(acted.in_force, 0) AS in_force,
               coalesce(acted.priors, 0) AS priors,
               coalesce(noted.notes, 0) AS notes,
               m.display_name, m.handle
        FROM people
        LEFT JOIN conduct ON conduct.user_id = people.user_id
        LEFT JOIN acted ON acted.user_id = people.user_id
        LEFT JOIN noted ON noted.user_id = people.user_id
        LEFT JOIN fd.member m ON m.user_id = people.user_id
        CONTEXT_JOIN
      )
    SQL

    CONTEXT_COLUMNS = ", dm.cohort_at, w.last_active_at".freeze

    IDENTITY_COLUMNS =
      ", mi.real_name, mi.first_name, mi.last_name, mi.email, cp.display_name AS shown_name".freeze

    IDENTITY_JOIN = <<~SQL
      LEFT JOIN fd.member_identity mi
        ON mi.user_id = people.user_id AND mi.purged_at IS NULL
      LEFT JOIN cachet_profiles cp ON cp.user_id = people.user_id
    SQL

    CONTEXT_JOIN = <<~SQL
      LEFT JOIN analytics.dim_member dm ON dm.user_id = people.user_id
      LEFT JOIN analytics.fct_member_window w
        ON w.user_id = people.user_id AND w.source = 'admin_analytics_member_range'
    SQL

    SORTS = {
      "subject" => "cases",
      "logged" => "logged_in",
      "actions" => "actions",
      "notes" => "notes"
    }.freeze

    private

    def aggregates
      columns = "m.display_name, m.handle, m.title"
      joins = []

      if context_asked?
        columns += CONTEXT_COLUMNS
        joins << CONTEXT_JOIN
      end

      if asked? && identity?
        columns += IDENTITY_COLUMNS
        joins << IDENTITY_JOIN
      end

      AGGREGATES.sub("m.display_name, m.handle", columns).sub("CONTEXT_JOIN", joins.join("\n"))
    end

    def context_asked?
      !default?("tenure") || !default?("active")
    end

    def roster_where
      parts = ["1 = 1"]
      parts << "(subject_of > 0 OR logged_in > 0)" unless self["who"] == "everyone"
      parts << "priors >= #{self['priors'].to_i}" unless default?("priors")
      parts << state_clause if state_clause
      parts << term_clause if asked?
      parts << tenure_clause unless default?("tenure")
      parts << active_clause unless default?("active")
      parts.compact.join(" AND ")
    end

    def state_clause
      case self["state"]
      when "open" then "open_cases > 0"
      when "force" then "in_force > 0"
      when "noted" then "notes > 0"
      when "clean" then "subject_of = 0 AND logged_in = 0"
      end
    end

    def tenure_clause
      days = "(current_date - cohort_at::date)"
      case self["tenure"]
      when "new" then "cohort_at IS NOT NULL AND #{days} < 31"
      when "year" then "cohort_at IS NOT NULL AND #{days} < 366"
      else "cohort_at IS NOT NULL AND #{days} >= 366"
      end
    end

    def active_clause
      days = "(current_date - last_active_at::date)"
      case self["active"]
      when "week" then "last_active_at IS NOT NULL AND #{days} <= 7"
      when "month" then "last_active_at IS NOT NULL AND #{days} <= 30"
      else "(last_active_at IS NULL OR #{days} > 90)"
      end
    end

    TERM_FIELDS = %w[user_id display_name handle title].freeze

    IDENTITY_TERM_FIELDS = %w[shown_name real_name first_name last_name email].freeze

    def term_fields
      identity? ? TERM_FIELDS + IDENTITY_TERM_FIELDS : TERM_FIELDS
    end

    def term_clause
      "(#{term_fields.map { |field| "#{field} ILIKE :term" }.join(' OR ')})"
    end

    def roster_order
      way = descending? ? "DESC" : "ASC"
      tie = descending? ? "ASC" : "DESC"

      case self["sort"]
      when "name"
        "lower(coalesce(nullif(display_name, ''), nullif(handle, ''), user_id)) " \
          "#{descending? ? 'ASC' : 'DESC'}, user_id #{tie}"
      when *SORTS.keys
        "#{SORTS.fetch(self['sort'])} #{way}, user_id #{tie}"
      else
        "last_case_at #{way} NULLS LAST, user_id #{tie}"
      end
    end

    def roster_binds
      { category: self["category"], now: Time.current,
        prior_since: Case::PRIOR_WINDOW.ago,
        term: "%#{Case.sanitize_sql_like(term)}%" }
    end

    def ask(sql, extra = {})
      Case.connection.select_all(Case.sanitize_sql([sql, roster_binds.merge(extra)]))
    end
  end
end
