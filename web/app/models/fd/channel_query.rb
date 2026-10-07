module Fd
  class ChannelQuery
    PER_PAGE = 40
    MIN_TERM = 2

    Row = Struct.new(:channel_id, :name, :visibility, :archived, :messages, :members,
      :last_active_at, keyword_init: true) do
      def label = name.present? ? "##{name}" : "unnamed channel"

      def private? = visibility == "private"

      def archived? = archived

      def quiet? = messages.to_i.zero?
    end

    FROM = <<~SQL.freeze
      FROM analytics.dim_channel c
      LEFT JOIN analytics.fct_channel_span s ON s.channel_id = c.channel_id
    SQL

    BUSIEST = ("c.archived, s.messages_posted DESC NULLS LAST, " \
               "c.last_active_at DESC NULLS LAST, c.name").freeze

    CLOSEST = ("CASE WHEN lower(c.name) = :exact OR lower(c.channel_id) = :exact THEN 0 " \
               "WHEN lower(c.name) LIKE :starts OR lower(c.channel_id) LIKE :starts THEN 1 " \
               "ELSE 2 END").freeze

    def initialize(params = {})
      @params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      @term = @params["q"].to_s.strip.delete_prefix("#")
      @page = [@params["page"].to_i, 1].max
    end

    attr_reader :term, :page

    def asked? = term.length >= MIN_TERM

    def rows
      @rows ||= begin
        found = ask(PER_PAGE + 1)
        @more = found.size > PER_PAGE
        found.first(PER_PAGE)
      end
    end

    def more?
      rows
      @more
    end

    def to_params
      { "q" => term.presence }.compact
    end

    private

    def ask(limit)
      sql = <<~SQL
        SELECT c.channel_id, c.name, c.visibility, c.archived, c.last_active_at,
               s.messages_posted, s.total_members
        #{FROM}#{where_clause}
        ORDER BY #{order}
        LIMIT :limit OFFSET :offset
      SQL

      Case.connection.select_all(Case.sanitize_sql([sql, binds(limit)])).to_a.map do |row|
        Row.new(channel_id: row["channel_id"], name: row["name"], visibility: row["visibility"],
          archived: row["archived"], messages: row["messages_posted"],
          members: row["total_members"], last_active_at: row["last_active_at"])
      end
    end

    def where_clause
      return "" unless asked?

      "WHERE (lower(c.name) LIKE :within OR lower(c.channel_id) LIKE :within)\n"
    end

    def order
      return BUSIEST unless asked?

      "#{CLOSEST}, #{BUSIEST}"
    end

    def binds(limit)
      held = { limit: limit, offset: (page - 1) * PER_PAGE }
      return held unless asked?

      text = term.downcase
      like = Case.sanitize_sql_like(text)
      held.merge(exact: text, starts: "#{like}%", within: "%#{like}%")
    end
  end
end
