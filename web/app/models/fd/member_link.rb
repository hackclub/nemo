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

      def evidence
        (signals || {}).map do |name, one|
          { "name" => name, "label" => MemberLink.label_for(name),
            "value" => one["value"], "people" => one["people"], "score" => one["score"] }
        end.sort_by { |one| -one["score"].to_f }
      end
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
