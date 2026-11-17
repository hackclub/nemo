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
      action_totals AS (
        SELECT target_user_id AS user_id,
               count(*) AS actions,
               count(DISTINCT case_id) FILTER (
                 WHERE reversed_at IS NULL AND performed_at >= :prior_since
               ) AS priors
        FROM fd.actions
        WHERE target_user_id IS NOT NULL
        GROUP BY target_user_id
      ),
      guard_totals AS (
        SELECT subject_id AS user_id, count(*) AS in_force
        FROM fd.member_guards
        WHERE state IN ('live', 'lifting')
        GROUP BY subject_id
      ),
      note_totals AS (
        SELECT subject_user_id AS user_id, count(*) AS notes
        FROM fd.notes
        WHERE case_id IS NULL AND subject_user_id IS NOT NULL AND deleted_at IS NULL
        GROUP BY subject_user_id
      ),
      link_totals AS (
        SELECT s.user_id, count(*) AS links
        FROM fd.member_link_side s
        WHERE s.score >= :strong AND NOT_DIFFERENT_PEOPLE
        GROUP BY s.user_id
      ),
      involved AS (
        SELECT p.user_id FROM fd.case_participants p
        JOIN fd.cases c ON c.id = p.case_id
        WHERE (:category = 'any' OR c.category_key = :category)
        UNION SELECT target_user_id FROM fd.actions WHERE target_user_id IS NOT NULL
        UNION SELECT subject_id FROM fd.member_guards WHERE state IN ('live', 'lifting')
        UNION SELECT subject_user_id FROM fd.notes
        WHERE case_id IS NULL AND subject_user_id IS NOT NULL AND deleted_at IS NULL
      ),
      candidate AS (CANDIDATE_SOURCE),
      roster AS (
        SELECT candidate.user_id,
               coalesce(conduct.cases, 0) AS cases,
               coalesce(conduct.subject_of, 0) AS subject_of,
               coalesce(conduct.logged_in, 0) AS logged_in,
               coalesce(conduct.open_cases, 0) AS open_cases,
               conduct.last_case_at,
               coalesce(action_totals.actions, 0) AS actions,
               coalesce(guard_totals.in_force, 0) AS in_force,
               coalesce(action_totals.priors, 0) AS priors,
               coalesce(note_totals.notes, 0) AS notes,
               coalesce(link_totals.links, 0) AS links,
               coalesce(m.is_deleted, false) AS deactivated,
               m.display_name, m.handle
        FROM candidate
        LEFT JOIN conduct ON conduct.user_id = candidate.user_id
        LEFT JOIN action_totals ON action_totals.user_id = candidate.user_id
        LEFT JOIN guard_totals ON guard_totals.user_id = candidate.user_id
        LEFT JOIN note_totals ON note_totals.user_id = candidate.user_id
        LEFT JOIN link_totals ON link_totals.user_id = candidate.user_id
        LEFT JOIN fd.member m ON m.user_id = candidate.user_id
        CONTEXT_JOIN
      )
    SQL

    EVERYONE = <<~SQL.squish.freeze
      SELECT user_id FROM fd.member WHERE is_deleted = false AND is_bot = false
      UNION ALL
      SELECT user_id FROM involved WHERE NOT EXISTS (
        SELECT 1 FROM fd.member live
        WHERE live.user_id = involved.user_id AND live.is_deleted = false AND live.is_bot = false
      )
    SQL

    INVOLVED = "SELECT user_id FROM involved".freeze
    DEACTIVATED = "SELECT user_id FROM fd.member WHERE is_deleted AND NOT is_bot".freeze

    LISTED_AGGREGATES = <<~SQL
      matched_user AS (
        SELECT user_id, match_rank FROM unnest(LISTED_IDS) WITH ORDINALITY AS found(user_id, match_rank)
      ),
      conduct AS (
        SELECT p.user_id,
               count(DISTINCT p.case_id) AS cases,
               count(*) FILTER (WHERE p.role = 'subject') AS subject_of,
               count(*) FILTER (WHERE p.role <> 'subject') AS logged_in,
               count(*) FILTER (WHERE p.role = 'subject' AND c.resolved_at IS NULL) AS open_cases,
               max(c.opened_at) AS last_case_at
        FROM fd.case_participants p
        JOIN fd.cases c ON c.id = p.case_id
        WHERE p.user_id IN (SELECT user_id FROM matched_user)
          AND (:category = 'any' OR c.category_key = :category)
        GROUP BY p.user_id
      ),
      action_totals AS (
        SELECT target_user_id AS user_id,
               count(*) AS actions,
               count(DISTINCT case_id) FILTER (
                 WHERE reversed_at IS NULL AND performed_at >= :prior_since
               ) AS priors
        FROM fd.actions
        WHERE target_user_id IN (SELECT user_id FROM matched_user)
        GROUP BY target_user_id
      ),
      guard_totals AS (
        SELECT subject_id AS user_id, count(*) AS in_force
        FROM fd.member_guards
        WHERE state IN ('live', 'lifting') AND subject_id IN (SELECT user_id FROM matched_user)
        GROUP BY subject_id
      ),
      note_totals AS (
        SELECT subject_user_id AS user_id, count(*) AS notes
        FROM fd.notes
        WHERE case_id IS NULL AND subject_user_id IN (SELECT user_id FROM matched_user) AND deleted_at IS NULL
        GROUP BY subject_user_id
      ),
      link_totals AS (
        SELECT s.user_id, count(*) AS links
        FROM fd.member_link_side s
        WHERE s.score >= :strong AND s.user_id IN (SELECT user_id FROM matched_user) AND NOT_DIFFERENT_PEOPLE
        GROUP BY s.user_id
      ),
      candidate AS (SELECT user_id, match_rank FROM matched_user),
      roster AS (
        SELECT candidate.user_id, candidate.match_rank,
               coalesce(conduct.cases, 0) AS cases,
               coalesce(conduct.subject_of, 0) AS subject_of,
               coalesce(conduct.logged_in, 0) AS logged_in,
               coalesce(conduct.open_cases, 0) AS open_cases,
               conduct.last_case_at,
               coalesce(action_totals.actions, 0) AS actions,
               coalesce(guard_totals.in_force, 0) AS in_force,
               coalesce(action_totals.priors, 0) AS priors,
               coalesce(note_totals.notes, 0) AS notes,
               coalesce(link_totals.links, 0) AS links,
               coalesce(m.is_deleted, false) AS deactivated,
               m.display_name, m.handle
        FROM candidate
        LEFT JOIN conduct ON conduct.user_id = candidate.user_id
        LEFT JOIN action_totals ON action_totals.user_id = candidate.user_id
        LEFT JOIN guard_totals ON guard_totals.user_id = candidate.user_id
        LEFT JOIN note_totals ON note_totals.user_id = candidate.user_id
        LEFT JOIN link_totals ON link_totals.user_id = candidate.user_id
        LEFT JOIN fd.member m ON m.user_id = candidate.user_id
        LEFT JOIN analytics.dim_member_cohort dm ON dm.user_id = candidate.user_id
        LEFT JOIN fd.member_joins mj ON mj.user_id = candidate.user_id
        LEFT JOIN fd.member_seen ms ON ms.user_id = candidate.user_id
        LEFT JOIN LATERAL (
          SELECT last_active_at, messages_posted FROM analytics.fct_member_window w
          WHERE w.source = 'admin_analytics_member_range' AND w.user_id = candidate.user_id LIMIT 1
        ) w ON true
      )
    SQL

    CONTEXT_COLUMNS =
      ", coalesce(dm.cohort_at, mj.joined_at) AS cohort_at, " \
      "greatest(w.last_active_at, ms.last_post_at, ms.last_login_at) AS last_active_at, " \
      "w.messages_posted".freeze

    CONTEXT_JOIN = <<~SQL
      LEFT JOIN analytics.dim_member_cohort dm ON dm.user_id = candidate.user_id
      LEFT JOIN fd.member_joins mj ON mj.user_id = candidate.user_id
      LEFT JOIN fd.member_seen ms ON ms.user_id = candidate.user_id
      LEFT JOIN analytics.fct_member_window w
        ON w.user_id = candidate.user_id AND w.source = 'admin_analytics_member_range'
    SQL

    SORTS = {
      "messages" => "messages_posted",
      "subject" => "cases",
      "logged" => "logged_in",
      "actions" => "actions",
      "notes" => "notes"
    }.freeze

    NAMES = "m.display_name, m.handle".freeze
    DISPLAY_COLUMNS = "m.display_name, m.handle, m.title".freeze

    private

    def aggregates
      searching? ? listed("ARRAY[:matching_ids]::text[]") : full_aggregates
    end

    def full_aggregates
      AGGREGATES.sub("NOT_DIFFERENT_PEOPLE", MemberLink::NOT_DIFFERENT_PEOPLE).sub(NAMES, include_context? ? DISPLAY_COLUMNS + CONTEXT_COLUMNS : DISPLAY_COLUMNS)
        .sub("CONTEXT_JOIN", include_context? ? CONTEXT_JOIN : "")
        .sub("CANDIDATE_SOURCE", candidate_source)
    end

    def listed(ids)
      LISTED_AGGREGATES.sub("NOT_DIFFERENT_PEOPLE", MemberLink::NOT_DIFFERENT_PEOPLE).sub(NAMES, DISPLAY_COLUMNS + CONTEXT_COLUMNS).sub("LISTED_IDS") { ids }
    end

    def paged_ids
      "ARRAY(WITH #{full_aggregates} SELECT user_id FROM roster WHERE #{roster_where} " \
        "ORDER BY #{sort_order} LIMIT :limit OFFSET :offset)"
    end

    def include_context?
      searching? || !default?("tenure") || !default?("active") || self["sort"] == "messages"
    end

    def candidate_source
      return DEACTIVATED if self["state"] == "gone"

      conduct_only? ? INVOLVED : EVERYONE
    end

    def conduct_only?
      self["who"] != "everyone" || !default?("priors") || %w[open force noted].include?(self["state"])
    end

    def roster_where
      parts = ["1 = 1"]
      parts << "(subject_of > 0 OR logged_in > 0)" unless self["who"] == "everyone"
      parts << "priors >= #{self['priors'].to_i}" unless default?("priors")
      parts << state_clause if state_clause
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
      when "linked" then "links > 0"
      when "gone" then "deactivated"
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

    def roster_order
      return sort_order unless searching?

      "match_rank, #{sort_order}"
    end

    def sort_order
      direction = descending? ? "DESC" : "ASC"
      tiebreak_direction = descending? ? "ASC" : "DESC"

      case self["sort"]
      when "name"
        "lower(coalesce(nullif(display_name, ''), nullif(handle, ''), user_id)) " \
          "#{descending? ? 'ASC' : 'DESC'}, user_id #{tiebreak_direction}"
      when *SORTS.keys
        "#{SORTS.fetch(self['sort'])} #{direction} NULLS LAST, user_id #{tiebreak_direction}"
      else
        "last_case_at #{direction} NULLS LAST, user_id #{tiebreak_direction}"
      end
    end

    def roster_binds
      binds = { category: self["category"], prior_since: Case::PRIOR_WINDOW.ago, strong: MemberLink::STRONG }
      searching? ? binds.merge(matching_ids: matching_ids) : binds
    end

    def select_rows(sql, extra = {})
      Case.connection.select_all(Case.sanitize_sql([sql, roster_binds.merge(extra)]))
    end
  end
end
