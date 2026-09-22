module Fd
  class JoinStanding
    REFUSALS = 20

    Refusal = Struct.new(:channel_id, :name, :why, :at, keyword_init: true) do
      def label = name.present? ? "##{name}" : channel_id
    end

    TURNED_DOWN = <<~SQL.freeze
      SELECT * FROM (
        SELECT DISTINCT ON (j.channel_id)
               j.channel_id, c.name, j.why, j.at
        FROM fd.channel_joins j
        LEFT JOIN analytics.dim_channel c ON c.channel_id = j.channel_id
        WHERE j.verb = 'refused'
          AND NOT EXISTS (
            SELECT 1 FROM fd.channel_membership m
            WHERE m.channel_id = j.channel_id AND m.inside
          )
        ORDER BY j.channel_id, j.at DESC
      ) latest
      ORDER BY at DESC
      LIMIT :limit
    SQL

    STILL_OUT = <<~SQL.freeze
      SELECT count(*) FROM analytics.dim_channel c
      WHERE c.archived = false AND c.visibility = 'public'
        AND NOT EXISTS (
          SELECT 1 FROM fd.channel_membership m
          WHERE m.channel_id = c.channel_id AND m.inside
        )
    SQL

    def initialize(mode = AppSetting.join_mode)
      @mode = mode
    end

    attr_reader :mode

    def swept? = ChannelMembership.exists?

    def seated = @seated ||= ChannelMembership.seated.count

    def guarded = @guarded ||= ChannelGuard.live.allowlists.distinct.count(:channel_id)

    def unattended = @unattended ||= (guarded_ids - seated_ids).size

    def waiting
      @waiting ||= case mode
      when AppSetting::GUARDED then unattended
      when AppSetting::ON then still_out
      else 0
      end
    end

    def refusals
      @refusals ||= Case.connection
        .select_all(Case.sanitize_sql([TURNED_DOWN, { limit: REFUSALS }])).to_a
        .map { |row| Refusal.new(**row.symbolize_keys) }
    end

    private

    def still_out
      Case.connection.select_value(STILL_OUT).to_i
    end

    def guarded_ids
      @guarded_ids ||= ChannelGuard.live.allowlists.distinct.pluck(:channel_id).to_set
    end

    def seated_ids
      @seated_ids ||= ChannelMembership.seated.pluck(:channel_id).to_set
    end
  end
end
