module Analytics
  class MartTopPosters < ApplicationRecord
    self.table_name = "analytics.mart_top_posters"

    Spread = Struct.new(:month, :posters, :top_tenth_share, :gini, keyword_init: true)

    SPREAD_SQL = <<~SQL.freeze
      with ranked as (
        select
          month,
          messages_posted,
          count(*) over (partition by month) as posters,
          sum(messages_posted) over (partition by month) as messages,
          row_number() over (partition by month order by messages_posted desc, user_id) as top_rank,
          row_number() over (partition by month order by messages_posted, user_id) as low_rank
        from analytics.mart_top_posters
        where messages_posted > 0 and month >= $1
      )
      select
        month,
        max(posters) as posters,
        sum(messages_posted) filter (where top_rank <= ceil(posters * 0.1))::numeric
          / nullif(max(messages), 0) * 100 as top_tenth_share,
        (2 * sum(low_rank * messages_posted)::numeric / nullif(max(posters) * max(messages), 0))
          - (max(posters) + 1)::numeric / nullif(max(posters), 0) as gini
      from ranked
      group by month
      order by month
    SQL

    def self.spread(months)
      from = (Date.current.beginning_of_month << (months - 1))
      WarehouseBuild.cached("top_poster_spread/#{months}") do
        connection.select_all(sanitize_sql_array([SPREAD_SQL.sub("$1", "?"), from])).map do |row|
          Spread.new(month: row["month"].to_date, posters: row["posters"].to_i,
            top_tenth_share: row["top_tenth_share"]&.to_f&.round(1),
            gini: row["gini"]&.to_f&.round(3))
        end
      end
    end

    def readonly?
      true
    end
  end
end
