module Fd
  class MemberSessions
    CROWDED = 20
    SHOWN = 12

    Address = Struct.new(:ip, :prefix, :country, :region, :isp, :first_at, :last_at,
      :seen, :people, :alongside, keyword_init: true) do
      def crowded? = people.to_i >= CROWDED

      def shared? = people.to_i > 1 && !crowded?

      def alone? = people.to_i <= 1

      def where
        [country, region.presence].compact_blank.join(" · ").presence
      end
    end

    Device = Struct.new(:app, :os, :addresses, :first_at, :last_at, :seen,
      keyword_init: true) do
      def name
        [app, os].compact_blank.join(" · ").presence || "Not recognised"
      end
    end

    def self.frame(user_id) = "member-sessions-#{user_id}"

    def self.with_prefix(prefix)
      return nil if prefix.nil?
      return prefix.to_s unless prefix.respond_to?(:prefix)

      "#{prefix}/#{prefix.prefix}"
    end

    def initialize(user_id)
      @user_id = user_id.to_s.upcase
    end

    attr_reader :user_id

    def rows
      @rows ||= LoginEvent.for_member(user_id).recent_first.limit(500).to_a
    end

    def any? = rows.any?

    def devices
      @devices ||= rows.group_by { |row| [row.ua_app, row.ua_os] }
        .map { |(app, os), held| device_for(app, os, held) }
        .sort_by { |one| -one.last_at.to_i }
        .first(SHOWN)
    end

    def addresses
      @addresses ||= devices.flat_map(&:addresses).uniq(&:prefix)
    end

    def failures
      @failures ||= rows.count(&:failed?)
    end

    def anomalies
      @anomalies ||= rows.count(&:anomaly?)
    end

    def first_at = rows.map(&:at).compact.min

    def last_at = rows.map(&:at).compact.max

    def address_count = prefixes.size

    def device_count = rows.map { |row| [row.ua_app, row.ua_os] }.uniq.size

    def alongside
      @alongside ||= addresses.flat_map(&:alongside).uniq
    end

    private

    def device_for(app, os, held)
      Device.new(
        app: app, os: os, addresses: addresses_in(held),
        first_at: held.map(&:at).compact.min, last_at: held.map(&:at).compact.max,
        seen: held.sum { |row| row.seen.to_i }
      )
    end

    def addresses_in(held)
      held.group_by { |row| self.class.with_prefix(row.ip_prefix) }.filter_map do |prefix, rows|
        next nil if prefix.nil?

        address_for(prefix, rows)
      end.sort_by { |one| -one.last_at.to_i }
    end

    def address_for(prefix, rows)
      people = cohorts[prefix].to_i
      Address.new(
        ip: rows.map(&:ip).compact.first, prefix: prefix,
        country: rows.map(&:country).compact.first,
        region: rows.map(&:region).compact.first,
        isp: rows.map(&:isp).compact.first,
        first_at: rows.map(&:at).compact.min, last_at: rows.map(&:at).compact.max,
        seen: rows.sum { |row| row.seen.to_i }, people: people,
        alongside: people.between?(2, CROWDED - 1) ? neighbours[prefix].to_a : []
      )
    end

    def prefixes
      @prefixes ||= rows.filter_map { |row| self.class.with_prefix(row.ip_prefix) }.uniq
    end

    def cohorts
      @cohorts ||= begin
        next_up = {}
        if prefixes.any?
          IpCohort.where(ip_prefix: prefixes).each do |one|
            next_up[self.class.with_prefix(one.ip_prefix)] = one.people
          end
        end
        next_up
      end
    end

    NEIGHBOURS = <<~SQL.squish.freeze
      SELECT DISTINCT ip_prefix::text AS prefix, user_id
      FROM fd.login_event
      WHERE ip_prefix = ANY(ARRAY[:prefixes]::inet[]) AND user_id <> :who
    SQL

    def neighbours
      @neighbours ||= begin
        found = Hash.new { |held, key| held[key] = [] }
        small = prefixes.select { |prefix| cohorts[prefix].to_i.between?(2, CROWDED - 1) }
        if small.any?
          ApplicationRecord.connection.select_all(
            ApplicationRecord.sanitize_sql([NEIGHBOURS, { prefixes: small, who: user_id }])
          ).each { |row| found[row["prefix"]] << row["user_id"] }
        end
        found
      end
    end
  end
end
