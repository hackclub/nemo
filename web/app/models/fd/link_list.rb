module Fd
  class LinkList
    VIEWS = {
      "review" => "Unreviewed",
      "certain" => "Certain",
      "strong" => "Strong",
      "weak" => "Weak",
      "actioned" => "Alt has actions",
      "labelled" => "Staff test",
      "reviewed" => "Reviewed",
      "sampled" => "Sampled"
    }.freeze
    DEFAULT_VIEW = "review".freeze
    STATUSES = {
      "review" => { "one_deactivated" => "One deactivated", "all" => "All" },
      "actioned" => { "any" => "Any", "one_deactivated" => "One deactivated",
                      "both_deactivated" => "Both deactivated", "neither_deactivated" => "Neither deactivated" }
    }.freeze
    DEFAULT_STATUSES = { "review" => "one_deactivated", "actioned" => "any" }.freeze
    STATUS_CONDITIONS = {
      "one_deactivated" => "coalesce(a.is_deleted, false) <> coalesce(b.is_deleted, false)",
      "both_deactivated" => "coalesce(a.is_deleted, false) AND coalesce(b.is_deleted, false)",
      "neither_deactivated" => "NOT coalesce(a.is_deleted, false) AND NOT coalesce(b.is_deleted, false)",
      "all" => "true",
      "any" => "true"
    }.freeze
    VERDICT_FILTERS = { "any" => "Any", "unreviewed" => "Unreviewed", "reviewed" => "Reviewed" }.freeze
    DEFAULT_VERDICT_FILTER = "any".freeze
    VERDICT_CONDITIONS = {
      "any" => "true",
      "unreviewed" => "v.a_user_id IS NULL",
      "reviewed" => "v.a_user_id IS NOT NULL"
    }.freeze
    LIVE_VARIANT = "live".freeze
    LIMIT = 100

    SIGNAL_GROUPS = {
      "network" => ["Network", "network_signals"],
      "device" => ["Device", "device_signals"],
      "email" => ["Email", "identity_signals"],
      "name" => ["Name", "name_signals"],
      "arrival" => ["Arrival", "arrival_signals"]
    }.freeze

    CONDITIONS = {
      "review" => "l.score >= :strong AND v.a_user_id IS NULL",
      "certain" => "l.score >= :certain AND v.a_user_id IS NULL",
      "strong" => "l.score >= :strong AND l.score < :certain AND v.a_user_id IS NULL",
      "weak" => "l.score < :strong AND l.label IS NULL AND v.a_user_id IS NULL",
      "actioned" => "l.score >= :strong AND (v.a_user_id IS NULL OR v.verdict <> 'different_people') AND " \
                    "EXISTS (SELECT 1 FROM fd.actions x WHERE x.target_user_id IN (l.a_user_id, l.b_user_id) " \
                    "AND x.reversed_at IS NULL)",
      "labelled" => "l.label IS NOT NULL AND v.a_user_id IS NULL",
      "reviewed" => "v.a_user_id IS NOT NULL",
      "sampled" => "EXISTS (SELECT 1 FROM fd.link_sample s WHERE s.variant = :variant " \
                   "AND s.a_user_id = l.a_user_id AND s.b_user_id = l.b_user_id)"
    }.freeze
    ORDER_PREFIX = { "reviewed" => "v.decided_at DESC,", "sampled" => "(v.a_user_id IS NOT NULL)," }.freeze

    SHADOW_LINKS = "(SELECT * FROM fd.member_link_shadow WHERE variant = :variant) l".freeze
    FROM = <<~SQL.squish.freeze
      fd.member_link l
      LEFT JOIN fd.member a ON a.user_id = l.a_user_id
      LEFT JOIN fd.member b ON b.user_id = l.b_user_id
      LEFT JOIN fd.member_link_verdict v ON v.a_user_id = l.a_user_id AND v.b_user_id = l.b_user_id
    SQL

    Row = Struct.new(:a_user_id, :b_user_id, :score, :label, :signals, :last_seen, :verdict, :decided_by,
      :decided_at, :note, :a_deleted, :b_deleted, keyword_init: true) do
      def band = LinkList.band(score)

      def evidence = MemberLink.evidence_of(signals)

      def verdict_label = LinkVerdict::VERDICTS.fetch(verdict, verdict)

      def deactivated_user_ids = [(a_user_id if a_deleted), (b_user_id if b_deleted)].compact
    end

    def self.band(score)
      return "certain" if score.to_f >= MemberLink::CERTAIN
      return "strong" if score.to_f >= MemberLink::STRONG

      "weak"
    end

    def self.signal_names(group)
      section = SIGNAL_GROUPS.dig(group, 1)
      section ? MemberLink::SIGNALS.fetch(section, {}).keys : []
    end

    def initialize(params = {})
      @params = params
    end

    def view
      requested = @params[:view].to_s
      VIEWS.key?(requested) ? requested : DEFAULT_VIEW
    end

    def statuses = STATUSES.fetch(view, {})

    def status = status_for(view)

    def verdict_filter = verdict_filter_for(view)

    def signal
      requested = @params[:signal].to_s
      SIGNAL_GROUPS.key?(requested) ? requested : nil
    end

    def signal_label = signal && SIGNAL_GROUPS.dig(signal, 0)

    def variants
      @variants ||= ApplicationRecord.connection
        .select_values("SELECT DISTINCT variant FROM fd.link_sample")
        .sort_by { |name| [name == LIVE_VARIANT ? 0 : 1, name] }
    end

    def variant
      requested = @params[:variant].to_s
      view == "sampled" && variants.include?(requested) ? requested : LIVE_VARIANT
    end

    def variant_label = variant == LIVE_VARIANT ? "Live links" : variant

    def page
      @page ||= [@params[:page].to_i, 1].max
    end

    def total_pages = (view_counts.fetch(view).to_f / LIMIT).ceil.clamp(1, Float::INFINITY).to_i

    def rows
      @rows ||= select_all(<<~SQL, limit: LIMIT, offset: (page - 1) * LIMIT).map { |row| build_row(row) }
        SELECT l.a_user_id, l.b_user_id, l.score, l.label, l.signals, l.last_seen,
               v.verdict, v.decided_by, v.decided_at, v.note,
               coalesce(a.is_deleted, false) AS a_deleted, coalesce(b.is_deleted, false) AS b_deleted
        FROM #{from_sql}
        WHERE #{condition(view)} #{signal_condition}
        ORDER BY #{ORDER_PREFIX[view]} l.score DESC, l.a_user_id, l.b_user_id
        LIMIT :limit OFFSET :offset
      SQL
    end

    def view_counts
      @view_counts ||= begin
        columns = CONDITIONS.keys.excluding("sampled").map { |key| "count(*) FILTER (WHERE #{condition(key)}) AS #{key}" }
        row = select_all("SELECT #{columns.join(', ')} FROM #{FROM}").first || {}
        sampled = select_all("SELECT count(*) AS sampled FROM #{from_sql} WHERE #{CONDITIONS.fetch('sampled')}").first || {}
        VIEWS.keys.index_with { |key| row.merge(sampled)[key].to_i }
      end
    end

    def signal_counts
      @signal_counts ||= begin
        columns = SIGNAL_GROUPS.keys.map do |group|
          "count(*) FILTER (WHERE l.signals ?| ARRAY[:#{group}]::text[]) AS #{group}"
        end
        binds = SIGNAL_GROUPS.keys.to_h { |group| [group.to_sym, LinkList.signal_names(group).presence || [""]] }
        row = select_all("SELECT #{columns.join(', ')} FROM #{from_sql} WHERE #{condition(view)}", binds).first || {}
        SIGNAL_GROUPS.keys.index_with { |group| row[group].to_i }
      end
    end

    def user_ids = rows.flat_map { |row| [row.a_user_id, row.b_user_id] }

    def params_for(view: self.view, status: self.status, verdict: verdict_filter, signal: self.signal,
      variant: self.variant, page: 1)
      { view: (view unless view == DEFAULT_VIEW),
        status: (status if STATUSES.fetch(view, {}).key?(status) && status != DEFAULT_STATUSES[view]),
        verdict: (verdict if view == "actioned" && verdict != DEFAULT_VERDICT_FILTER), signal: signal,
        variant: (variant if view == "sampled" && variant != LIVE_VARIANT),
        page: (page if page > 1) }.compact
    end

    private

    def condition(key)
      return CONDITIONS.fetch(key) unless STATUSES.key?(key)

      clauses = [CONDITIONS.fetch(key), STATUS_CONDITIONS.fetch(status_for(key))]
      clauses << VERDICT_CONDITIONS.fetch(verdict_filter_for(key)) if key == "actioned"
      clauses.join(" AND ")
    end

    def status_for(key)
      requested = @params[:status].to_s
      key == view && STATUSES.fetch(key, {}).key?(requested) ? requested : DEFAULT_STATUSES[key]
    end

    def verdict_filter_for(key)
      requested = @params[:verdict].to_s
      key == "actioned" && key == view && VERDICT_FILTERS.key?(requested) ? requested : DEFAULT_VERDICT_FILTER
    end

    def from_sql
      variant == LIVE_VARIANT ? FROM : FROM.sub("fd.member_link l", SHADOW_LINKS)
    end

    def signal_condition
      signal ? "AND l.signals ?| ARRAY[:signal_names]::text[]" : ""
    end

    def select_all(sql, extra = {})
      binds = { strong: MemberLink::STRONG, certain: MemberLink::CERTAIN, variant: variant,
                signal_names: LinkList.signal_names(signal).presence || [""] }.merge(extra)
      ApplicationRecord.connection.select_all(ApplicationRecord.sanitize_sql([sql, binds])).to_a
    end

    def build_row(row)
      flag = ActiveModel::Type::Boolean.new
      Row.new(a_user_id: row["a_user_id"], b_user_id: row["b_user_id"], score: row["score"].to_f,
        label: row["label"], signals: MemberLink.parsed(row["signals"]), last_seen: row["last_seen"],
        verdict: row["verdict"], decided_by: row["decided_by"], decided_at: row["decided_at"], note: row["note"],
        a_deleted: flag.cast(row["a_deleted"]) || false, b_deleted: flag.cast(row["b_deleted"]) || false)
    end
  end
end
