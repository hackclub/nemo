module Admin
  class ChannelsController < BaseController
    SEARCH_SHOWN = 100

    BANDS = [
      ["public", "Everyone signed in"],
      ["granted", "Named people only"]
    ].freeze

    PICK_SHOWN = 40

    def search
      term = params[:q].to_s.strip.delete_prefix("#")
      scope = Analytics::DimChannel.where(archived: false)
      if term.present?
        like = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
        scope = scope.where("dim_channel.name ILIKE :like OR " \
                            "dim_channel.channel_id ILIKE :like", like: like)
      end

      render json: {
        channels: biggest_first(scope).limit(PICK_SHOWN)
          .pluck(:channel_id, :name).map { |id, name| { id: id, name: name } },
        total: scope.count
      }
    end

    SPAN = "LEFT JOIN analytics.fct_channel_span s " \
           "ON s.channel_id = dim_channel.channel_id".freeze

    def biggest_first(scope)
      scope.joins(SPAN).order(Arel.sql("s.total_members DESC NULLS LAST, dim_channel.name"))
    end

    def index
      @q = params[:q].to_s.strip
      @settings = Channels::Audience::Setting.all.index_by(&:channel_id)
      @grants = Channels::Audience::Grant.live.to_a.group_by(&:channel_id)
      @total = Analytics::DimChannel.where(archived: false).count
      @bands = band(listed)
      @open = @bands.reject { |kind, _label, _rows| kind == "granted" }
        .sum { |_kind, _label, rows| rows.size }
      named = @grants.values.flatten
      @names = Fd::Names.for(named.map(&:user_id) + named.map(&:granted_by))
    end

    def update
      return refuse unless may_community?("analytics.channel.share")

      wanted = params[:audience].to_s
      unless Channels::Audience::KINDS.include?(wanted)
        return redirect_to(admin_channels_path, alert: "#{wanted} is not an audience")
      end

      row = Channels::Audience::Setting.find_or_initialize_by(channel_id: params[:channel_id])
      was = row.audience
      row.update!(audience: wanted, set_by: current_staff.user_id, set_at: Time.current)
      Fd::Audit.record(row, wanted == "granted" ? "revoked" : "granted",
        actor: current_staff.user_id, request_id: request.request_id,
        entity_id: row.channel_id,
        before: { "channel_id" => row.channel_id, "audience" => was },
        after: { "channel_id" => row.channel_id, "audience" => wanted })
      redirect_to admin_channels_path(q: params[:q].presence),
        notice: "##{params[:channel_id]} is #{wanted}"
    end

    private

    def like_q
      ActiveRecord::Base.sanitize_sql_like(@q)
    end

    def refuse
      redirect_to admin_channels_path,
        alert: Community::Access.why_not(current_staff, "analytics.channel.share")
    end

    def listed
      scope = Analytics::DimChannel.where(archived: false)
      if @q.present?
        return scope.where("dim_channel.name ILIKE ?", "%#{like_q}%")
          .order(:name).limit(SEARCH_SHOWN)
      end


      open_ids = @settings.values.select { |row| Channels::Audience::OPEN.include?(row.audience) }
        .map(&:channel_id)
      scope.where(channel_id: open_ids).or(scope.where(channel_id: @grants.keys)).order(:name)
    end

    def band(channels)
      grouped = channels.group_by { |channel| audience(channel.channel_id) }
      BANDS.filter_map { |kind, label|
        rows = grouped[kind]
        [kind, label, rows] if rows.present?
      }
    end

    def audience(channel_id)
      Channels::Audience.settled(@settings[channel_id]&.audience ||
        Channels::Audience::DEFAULT)
    end
    helper_method :audience
  end
end
