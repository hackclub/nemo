module Fd
  class MemberMention
    PAGE_ROWS = 25
    SQL = "SELECT * FROM fd.member_mentions(?, ?::timestamptz, ?)".freeze

    Row = Struct.new(:channel_id, :ts, :thread_root_ts, :posted_at, :author_id, :author_kind,
      keyword_init: true) do
      def reply? = thread_root_ts.present? && thread_root_ts != ts
    end

    Page = Struct.new(:rows, :next_before, keyword_init: true)

    def self.page(user_id, before: nil, limit: PAGE_ROWS)
      sql = ApplicationRecord.sanitize_sql_array([SQL, user_id, before&.utc&.iso8601(6), limit + 1])
      rows = ApplicationRecord.connection.select_all(sql, "Fd::MemberMention").map { |row| build(row) }
      shown = rows.first(limit)
      Page.new(rows: shown, next_before: (shown.last.posted_at if rows.size > limit))
    end

    def self.build(row)
      posted_at = row["posted_at"]
      posted_at = Time.zone.parse(posted_at) if posted_at.is_a?(String)
      Row.new(channel_id: row["channel_id"], ts: row["ts"], thread_root_ts: row["thread_root_ts"],
        posted_at: posted_at, author_id: row["author_id"], author_kind: row["author_kind"])
    end
  end
end
