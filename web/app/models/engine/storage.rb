module Engine
  class Storage
    Table = Struct.new(:name, :bytes, :rows, :grew, :median, :flagged, keyword_init: true) do
      def flagged? = flagged
    end

    LATEST_SQL = <<~SQL.squish.freeze
      SELECT day, table_name, bytes, rows, grew, median_growth, flagged
      FROM   ingest.table_size
      WHERE  day = (SELECT max(day) FROM ingest.table_size)
      ORDER  BY bytes DESC, table_name
    SQL

    def self.latest
      rows = ApplicationRecord.connection.select_all(LATEST_SQL).to_a
      new(rows.first&.fetch("day"), rows.map { |row| table_for(row) })
    end

    def self.table_for(row)
      Table.new(name: row["table_name"], bytes: row["bytes"].to_i, rows: row["rows"]&.to_i,
        grew: row["grew"]&.to_i, median: row["median_growth"]&.to_i, flagged: row["flagged"])
    end

    def initialize(day, tables)
      @day = day
      @tables = tables
    end

    attr_reader :day, :tables

    def any? = tables.any?

    def bytes = tables.sum(&:bytes)

    def grew = tables.filter_map(&:grew).sum

    def flagged = tables.count(&:flagged?)
  end
end
