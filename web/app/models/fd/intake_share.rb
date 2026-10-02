module Fd
  class IntakeShare < ApplicationRecord
    self.table_name = "fd.intake_shares"

    FORWARD = "forward".freeze

    WHAT_IT_IS = {
      "forward" => "forwarded",
      "unfurl" => "linked",
      "link" => "linked"
    }.freeze

    def forwarded?
      kind == FORWARD
    end

    def said?
      is_reachable && source_body.present?
    end

    def word
      WHAT_IT_IS.fetch(kind, "linked")
    end

    def why_not
      "a link we could not open" unless said?
    end

    Cited = Struct.new(:case_id, :body, :kind, :author, :channel, :permalink,
      keyword_init: true) do
      def forwarded? = kind == "forward"

      def word = forwarded? ? "forwarded" : "linked"
    end

    FIRST_WORDS = <<~SQL.freeze
      SELECT DISTINCT ON (r.case_id) r.case_id, s.source_body, s.kind,
             s.source_author_user_id, s.source_channel_id, s.permalink
      FROM fd.intake_shares s
      JOIN fd.intake_messages m ON m.id = s.message_id
      JOIN fd.intake_conversations v ON v.id = m.conversation_id
      JOIN fd.case_reports r ON r.id = v.report_id
      WHERE r.case_id IN (:case_ids)
        AND s.is_reachable
        AND btrim(coalesce(s.source_body, '')) <> ''
      ORDER BY r.case_id, m.posted_at, s.id
    SQL

    def self.first_words_for(case_ids)
      ids = Array(case_ids).compact.uniq
      return {} if ids.empty?

      rows = connection.select_all(sanitize_sql([FIRST_WORDS, { case_ids: ids }]))
      rows.to_a.to_h { |row|
        [row["case_id"], Cited.new(case_id: row["case_id"], body: row["source_body"],
          kind: row["kind"], author: row["source_author_user_id"],
          channel: row["source_channel_id"], permalink: row["permalink"])]
      }
    end

    def self.for_messages(message_ids)
      ids = Array(message_ids).compact.uniq
      return {} if ids.empty?

      where(message_id: ids).order(:message_id, :id).group_by(&:message_id)
    end
  end
end
