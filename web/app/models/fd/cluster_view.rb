module Fd
  class ClusterView
    DAYS_SHOWN = 60

    Member = Struct.new(:user_id, :joined_at, :active, :deactivated, keyword_init: true)
    Edge = Struct.new(:a_user_id, :b_user_id, :score, :top_signal, :signals, :label, :verdict,
      keyword_init: true)
    Sighting = Struct.new(:user_id, :hour, :ip, :hits, keyword_init: true)
    Snapshot = Struct.new(:id, :user_id, :deactivated_at, :source, :actor_id, :reason, :traits,
      :links, keyword_init: true)

    MEMBERS_SQL = <<~SQL.squish.freeze
      SELECT c.user_id, c.active, c.ring, c.conflict, j.joined_at, coalesce(m.is_deleted, false) AS deactivated
      FROM fd.member_cluster c
      LEFT JOIN fd.member_joins j ON j.user_id = c.user_id
      LEFT JOIN fd.member m ON m.user_id = c.user_id
      WHERE c.cluster_id = :cluster_id
      ORDER BY j.joined_at NULLS LAST, c.user_id
    SQL

    EDGES_SQL = <<~SQL.squish.freeze
      SELECT coalesce(l.a_user_id, v.a_user_id) AS a_user_id, coalesce(l.b_user_id, v.b_user_id) AS b_user_id,
             l.score, l.top_signal, l.signals, l.label, v.verdict
      FROM (SELECT * FROM fd.member_link
            WHERE a_user_id IN (:ids) AND b_user_id IN (:ids)) l
      FULL JOIN (SELECT * FROM fd.member_link_verdict
                 WHERE a_user_id IN (:ids) AND b_user_id IN (:ids)) v
        ON v.a_user_id = l.a_user_id AND v.b_user_id = l.b_user_id
      ORDER BY l.score DESC NULLS LAST, 1, 2
    SQL

    SIGHTINGS_SQL = <<~SQL.squish.freeze
      SELECT user_id, hour, host(ip) AS ip, sum(hits) AS hits
      FROM fd.login_event
      WHERE user_id IN (:ids) AND ip IS NOT NULL AND hour >= :since
      GROUP BY user_id, hour, ip
      ORDER BY hour
    SQL

    SNAPSHOTS_SQL = <<~SQL.squish.freeze
      SELECT id, user_id, deactivated_at, source, actor_id, reason, traits, links
      FROM fd.evidence_snapshot
      WHERE user_id IN (:ids)
      ORDER BY deactivated_at DESC
    SQL

    def self.find(cluster_id)
      view = new(cluster_id.to_s.upcase)
      view.members.any? ? view : nil
    end

    def initialize(cluster_id)
      @cluster_id = cluster_id
    end

    attr_reader :cluster_id

    def members
      @members ||= rows(MEMBERS_SQL, cluster_id: cluster_id).map do |row|
        @flags ||= { ring: flag(row["ring"]), conflict: flag(row["conflict"]) }
        Member.new(user_id: row["user_id"], joined_at: time(row["joined_at"]),
          active: flag(row["active"]), deactivated: flag(row["deactivated"]))
      end
    end

    def ids = members.map(&:user_id)

    def ring? = members.any? && @flags[:ring]

    def conflict? = members.any? && @flags[:conflict]

    def active = members.select(&:active)

    def edges
      @edges ||= rows(EDGES_SQL, ids: ids).map do |row|
        Edge.new(a_user_id: row["a_user_id"], b_user_id: row["b_user_id"],
          score: row["score"]&.to_f, top_signal: row["top_signal"],
          signals: MemberLink.parsed(row["signals"]), label: row["label"], verdict: row["verdict"])
      end
    end

    def since
      oldest = members.filter_map(&:joined_at).min
      floor = DAYS_SHOWN.days.ago.beginning_of_day
      oldest && oldest > floor ? oldest.beginning_of_hour : floor
    end

    def sightings
      @sightings ||= rows(SIGHTINGS_SQL, ids: ids, since: since).map do |row|
        Sighting.new(user_id: row["user_id"], hour: time(row["hour"]), ip: row["ip"],
          hits: row["hits"].to_i)
      end
    end

    def shared_ips
      @shared_ips ||= sightings.group_by(&:ip).select { |_ip, seen| seen.map(&:user_id).uniq.size > 1 }
        .keys.sort
    end

    def snapshots
      @snapshots ||= rows(SNAPSHOTS_SQL, ids: ids).map do |row|
        Snapshot.new(id: row["id"].to_i, user_id: row["user_id"], deactivated_at: time(row["deactivated_at"]),
          source: row["source"], actor_id: row["actor_id"], reason: row["reason"],
          traits: MemberLink.parsed(row["traits"]), links: MemberLink.parsed(row["links"]))
      end
    end

    def map_data
      joined = members.filter_map(&:joined_at)
      {
        nodes: members.map do |one|
          { id: one.user_id, joined: one.joined_at&.iso8601, active: one.active,
            deactivated: one.deactivated, oldest: one.user_id == cluster_id }
        end,
        edges: edges.map do |one|
          { a: one.a_user_id, b: one.b_user_id, score: one.score, verdict: one.verdict,
            band: band_of(one.score) }
        end,
        first: joined.min&.iso8601, last: joined.max&.iso8601
      }
    end

    def timeline_data
      {
        rows: members.map(&:user_id),
        since: since.iso8601,
        until: Time.current.iso8601,
        shared: shared_ips,
        marks: sightings.map { |one| { user: one.user_id, hour: one.hour.iso8601, ip: one.ip, hits: one.hits } }
      }
    end

    private

    def band_of(score)
      return "verdict" if score.nil?
      return "certain" if score >= MemberLink::CERTAIN
      return "strong" if score >= MemberLink::STRONG

      "worth"
    end

    def rows(sql, binds)
      return [] if binds.key?(:ids) && binds[:ids].empty?

      ApplicationRecord.connection.select_all(ApplicationRecord.sanitize_sql([sql, binds])).to_a
    end

    def flag(value) = ActiveModel::Type::Boolean.new.cast(value) || false

    def time(value)
      return nil if value.nil?

      value.is_a?(String) ? Time.zone.parse(value) : value
    end
  end
end
