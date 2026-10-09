module Fd
  class MemberLink < ApplicationRecord
    self.table_name = "fd.member_link"

    SIGNALS = YAML.load_file(Rails.root.join("../db/alt_signals.yml")).freeze
    SECTIONS = %w[network_signals device_signals identity_signals name_signals arrival_signals].freeze
    CATALOGUE = SECTIONS.reduce({}) { |held, section| held.merge(SIGNALS.fetch(section, {})) }.freeze
    BANDS = SIGNALS.fetch("scoring").freeze

    STRONG = BANDS.fetch("strong")
    CERTAIN = BANDS.fetch("certain")
    MOST = BANDS.fetch("most_per_member", 25)

    Side = Struct.new(:user_id, :other_id, :score, :top_signal, :signals,
      :first_seen, :last_seen, keyword_init: true) do
      def certain? = score.to_f >= CERTAIN

      def strong? = score.to_f >= STRONG && !certain?

      def band
        return "certain" if certain?
        return "strong" if strong?

        "worth a look"
      end

      def signal_names = (signals || {}).keys

      def evidence = MemberLink.evidence_of(signals)
    end

    Pair = Struct.new(:active_id, :deactivated_id, :score, :top_signal, :signals, :last_seen,
      keyword_init: true) do
      def evidence = MemberLink.evidence_of(signals)
    end

    Cluster = Struct.new(:cluster_id, :accounts, :active, :ring, :conflict, keyword_init: true)

    REVIEW_SQL = <<~SQL.squish.freeze
      SELECT l.a_user_id, l.b_user_id, a.is_deleted AS a_gone, l.score, l.top_signal, l.signals,
             l.last_seen
      FROM fd.member_link l
      JOIN fd.member a ON a.user_id = l.a_user_id
      JOIN fd.member b ON b.user_id = l.b_user_id
      WHERE l.score >= :strong AND a.is_deleted <> b.is_deleted
        AND NOT EXISTS (SELECT 1 FROM fd.member_link_verdict v
                        WHERE v.a_user_id = l.a_user_id AND v.b_user_id = l.b_user_id)
      ORDER BY l.score DESC, l.a_user_id, l.b_user_id
      LIMIT :limit
    SQL

    CLUSTERS_SQL = <<~SQL.squish.freeze
      SELECT cluster_id, max(accounts) AS accounts, count(*) FILTER (WHERE active) AS active,
             bool_or(ring) AS ring, bool_or(conflict) AS conflict
      FROM fd.member_cluster
      GROUP BY cluster_id
      ORDER BY bool_or(conflict) DESC, bool_or(ring) DESC, max(accounts) DESC, cluster_id
      LIMIT :limit
    SQL

    MATES_SQL = <<~SQL.squish.freeze
      SELECT mate.user_id
      FROM fd.member_cluster mine
      JOIN fd.member_cluster mate ON mate.cluster_id = mine.cluster_id AND mate.user_id <> mine.user_id
      WHERE mine.user_id = :user_id
      ORDER BY mate.user_id
    SQL

    def self.evidence_of(signals)
      (signals || {}).map do |name, one|
        { "name" => name, "label" => label_for(name),
          "value" => one["value"], "people" => one["people"], "score" => one["score"] }
      end.sort_by { |one| -one["score"].to_f }
    end

    def self.needs_review(limit: 100)
      flag = ActiveModel::Type::Boolean.new
      rows = connection.select_all(sanitize_sql([REVIEW_SQL, { strong: STRONG, limit: limit }]))
      rows.map do |row|
        gone = flag.cast(row["a_gone"])
        Pair.new(
          active_id: gone ? row["b_user_id"] : row["a_user_id"],
          deactivated_id: gone ? row["a_user_id"] : row["b_user_id"],
          score: row["score"].to_f, top_signal: row["top_signal"],
          signals: parsed(row["signals"]), last_seen: row["last_seen"]
        )
      end
    end

    def self.clusters(limit: 100)
      flag = ActiveModel::Type::Boolean.new
      connection.select_all(sanitize_sql([CLUSTERS_SQL, { limit: limit }])).map do |row|
        Cluster.new(cluster_id: row["cluster_id"], accounts: row["accounts"].to_i,
          active: row["active"].to_i, ring: flag.cast(row["ring"]),
          conflict: flag.cast(row["conflict"]))
      end
    end

    def self.cluster_mates(user_id, except: [])
      return [] if user_id.blank?

      connection.select_values(sanitize_sql([MATES_SQL, { user_id: user_id }])) - except
    end

    def self.label_for(name)
      (CATALOGUE[name] || {})["label"] || name.to_s.tr("_", " ")
    end

    def self.for_member(user_id, limit: MOST)
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
      held = order(score: :desc).limit(limit)
      over ? held.where("score >= ?", over) : held
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
