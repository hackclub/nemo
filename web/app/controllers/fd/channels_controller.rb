module Fd
  class ChannelsController < BaseController
    permit "case.read"

    def index
      @query = ChannelQuery.new(params)
      @rows = @query.rows
      @open_id = params[:open].to_s.presence
      @joining = JoinStanding.new
    end

    ACTIVITY_SHOWN = 50

    def show
      @channel_id = params[:channel_id].to_s.strip.upcase
      @channel = Analytics::DimChannel.find_by(channel_id: @channel_id)
      @guard = ChannelGuard.live_for(@channel_id)
      @allows = @guard ? @guard.allows.oldest_first.to_a : []
      @standing = ChannelJoin.latest_for(@channel_id)
      @seat = ChannelMembership.inside?(@channel_id)
      @events = ChannelGuardEvent.where(channel_id: @channel_id)
        .newest_first.limit(ACTIVITY_SHOWN).to_a
      @labels = labels_for(@events)
      @app_ids = app_ids_for(@allows)
      @names = Names.for(@guard ? @guard.people_named : [])
      load_pane
    end

    def pane
      query = ChannelQuery.new(params)
      rows = query.rows
      more = (fd_channel_pane_path(query.to_params.merge(page: query.page + 1)) if query.more?)

      render partial: "fd/channels/pane_rows", layout: false,
        locals: { rows: rows, open_id: params[:open].to_s.presence, more: more }
    end

    private

    def app_ids_for(allows)
      ids = allows.map(&:subject_id)
      return {} if ids.empty?

      ChannelGuardEvent.where(subject_id: ids).where.not(app_id: nil)
        .order(:at).pluck(:subject_id, :app_id).to_h
    end

    def labels_for(events)
      ids = events.map(&:subject_id).uniq
      return {} if ids.empty?

      vouched = ChannelGuardAllow.where(subject_id: ids).where.not(label: nil)
        .pluck(:subject_id, :label).to_h
      known = Member.where(user_id: ids).to_h { |one| [one.user_id, one.name] }
      known.merge(vouched)
    end

    def load_pane
      @query = ChannelQuery.new(params.to_unsafe_h.slice("q"))
      @rows = @query.rows
      @open_id = @channel_id
    end
  end
end
