module Fd
  class ChannelsController < BaseController
    permit "case.read"

    def index
      @query = ChannelQuery.new(params)
      @rows = @query.rows
      @open_id = params[:open].to_s.presence
    end

    def show
      @channel_id = params[:channel_id].to_s.strip.upcase
      @channel = Analytics::DimChannel.find_by(channel_id: @channel_id)
      @guard = ChannelGuard.live_for(@channel_id)
      @allows = @guard ? @guard.allows.oldest_first.to_a : []
      @standing = ChannelJoin.latest_for(@channel_id)
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

    def load_pane
      @query = ChannelQuery.new(params.to_unsafe_h.slice("q"))
      @rows = @query.rows
      @open_id = @channel_id
    end
  end
end
