module Fd
  class MemberLink < ApplicationRecord
    self.table_name = "fd.member_link"

    SIGNALS = YAML.load_file(Rails.root.join("../db/alt_signals.yml")).freeze
    SECTIONS = %w[network_signals device_signals identity_signals name_signals arrival_signals].freeze
    CATALOGUE = SECTIONS.reduce({}) { |merged, section| merged.merge(SIGNALS.fetch(section, {})) }.freeze
    BANDS = SIGNALS.fetch("scoring").freeze

    STRONG = BANDS.fetch("strong")
    CERTAIN = BANDS.fetch("certain")
    MEMBER_LINK_LIMIT = 25
    CLUSTER_MEMBER_LIMIT = 16

    Side = Struct.new(:user_id, :other_id, :score, :top_signal, :signals,
      :first_seen, :last_seen, keyword_init: true) do
      def certain? = score.to_f >= CERTAIN

      def strong? = score.to_f >= STRONG && !certain?

      def band
        return "certain" if certain?
        return "strong" if strong?

        "weak"
      end

      def signal_names = (signals || {}).keys

      def evidence = MemberLink.evidence_of(signals)
    end

    Cluster = Struct.new(:cluster_id, :accounts, :active, :ring, :conflict, keyword_init: true)

    LinkCounts = Struct.new(:count, :certain, :strong, keyword_init: true)

    LINK_COUNTS_SQL = <<~SQL.squish.freeze
      SELECT count(*) AS links,
             count(*) FILTER (WHERE score >= :certain) AS certain,
             count(*) FILTER (WHERE score >= :strong AND score < :certain) AS strong
      FROM fd.member_link_side
      WHERE user_id = :user_id
    SQL

    CLUSTER_SQL = <<~SQL.squish.freeze
      SELECT cluster_id, accounts, ring, conflict FROM fd.member_cluster WHERE user_id = :user_id
    SQL

    REVIEW_COUNT_SQL = <<~SQL.squish.freeze
      SELECT count(*)
      FROM fd.member_link l
      JOIN fd.member a ON a.user_id = l.a_user_id
      JOIN fd.member b ON b.user_id = l.b_user_id
      WHERE l.score >= :strong AND a.is_deleted <> b.is_deleted
        AND NOT EXISTS (SELECT 1 FROM fd.member_link_verdict v
                        WHERE v.a_user_id = l.a_user_id AND v.b_user_id = l.b_user_id)
    SQL

    REVIEW_COUNT_TTL = 1.minute

    CLUSTERS_FOR_MEMBERS_SQL = <<~SQL.squish.freeze
      SELECT cluster_id, max(accounts) AS accounts, count(*) FILTER (WHERE active) AS active,
             bool_or(ring) AS ring, bool_or(conflict) AS conflict
      FROM fd.member_cluster
      WHERE cluster_id IN (SELECT cluster_id FROM fd.member_cluster WHERE user_id IN (:ids))
      GROUP BY cluster_id
      ORDER BY max(accounts) DESC, cluster_id
      LIMIT :limit
    SQL

    CLUSTER_MEMBERS_SQL = <<~SQL.squish.freeze
      SELECT peer.user_id, peer.active
      FROM fd.member_cluster subject_member
      JOIN fd.member_cluster peer ON peer.cluster_id = subject_member.cluster_id AND peer.user_id <> subject_member.user_id
      WHERE subject_member.user_id = :user_id
      ORDER BY peer.active DESC, peer.user_id
    SQL

    def self.evidence_of(signals)
      (signals || {}).map do |name, signal|
        { "name" => name, "label" => label_for(name),
          "value" => signal["value"], "people" => signal["people"], "score" => signal["score"] }
      end.sort_by { |entry| -entry["score"].to_f }
    end

    def self.review_count
      count, counted_at = @review_count
      return count if counted_at&.after?(REVIEW_COUNT_TTL.ago)

      connection.select_value(sanitize_sql([REVIEW_COUNT_SQL, { strong: STRONG }])).to_i
        .tap { |fresh| @review_count = [fresh, Time.current] }
    end

    def self.clusters_for_members(user_ids, limit: 3)
      return [] if user_ids.empty?

      flag = ActiveModel::Type::Boolean.new
      connection.select_all(sanitize_sql([CLUSTERS_FOR_MEMBERS_SQL, { ids: user_ids, limit: limit }])).map do |row|
        Cluster.new(cluster_id: row["cluster_id"], accounts: row["accounts"].to_i,
          active: row["active"].to_i, ring: flag.cast(row["ring"]),
          conflict: flag.cast(row["conflict"]))
      end
    end

    def self.link_counts_for(user_id)
      row = connection.select_one(sanitize_sql([LINK_COUNTS_SQL,
        { user_id: user_id, certain: CERTAIN, strong: STRONG }])) || {}
      LinkCounts.new(count: row["links"].to_i, certain: row["certain"].to_i, strong: row["strong"].to_i)
    end

    def self.cluster_for(user_id)
      row = connection.select_one(sanitize_sql([CLUSTER_SQL, { user_id: user_id }]))
      return nil if row.nil?

      flag = ActiveModel::Type::Boolean.new
      Cluster.new(cluster_id: row["cluster_id"], accounts: row["accounts"].to_i,
        ring: flag.cast(row["ring"]), conflict: flag.cast(row["conflict"]))
    end

    def self.cluster_of(user_id)
      return nil if user_id.blank?

      connection.select_value(sanitize_sql([
        "SELECT cluster_id FROM fd.member_cluster WHERE user_id = ?", user_id
      ]))
    end

    def self.cluster_members(user_id, except: [])
      return {} if user_id.blank?

      connection.select_rows(sanitize_sql([CLUSTER_MEMBERS_SQL, { user_id: user_id }]))
        .reject { |other_user_id, _| except.include?(other_user_id) }
        .to_h { |other_user_id, active| [other_user_id, ActiveModel::Type::Boolean.new.cast(active) || false] }
    end

    def self.label_for(name)
      (CATALOGUE[name] || {})["label"] || name.to_s.tr("_", " ")
    end

    def self.for_member(user_id, limit: MEMBER_LINK_LIMIT)
      return [] if user_id.blank?

      rows = connection.select_all(sanitize_sql([<<~SQL.squish, user_id, limit]))
        SELECT user_id, other_id, score, top_signal, signals, first_seen, last_seen
        FROM fd.member_link_side WHERE user_id = ? ORDER BY score DESC LIMIT ?
      SQL

      rows.map do |row|
        Side.new(
          user_id: row["user_id"], other_id: row["other_id"], score: row["score"].to_f,
          top_signal: row["top_signal"], signals: parsed(row["signals"]),
          first_seen: row["first_seen"], last_seen: row["last_seen"]
        )
      end
    end

    def self.parsed(value)
      value.is_a?(String) ? JSON.parse(value) : (value || {})
    rescue JSON::ParserError
      {}
    end

    def self.strongest(limit: 50, over: nil)
      relation = order(score: :desc).limit(limit)
      over ? relation.where("score >= ?", over) : relation
    end

    def self.counted_for(user_id)
      return 0 if user_id.blank?

      connection.select_value(sanitize_sql([
        "SELECT count(*) FROM fd.member_link_side WHERE user_id = ?", user_id
      ])).to_i
    end

    def readonly? = persisted?
  end
end
