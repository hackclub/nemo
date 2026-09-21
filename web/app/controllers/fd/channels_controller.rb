module Fd
  class ChannelsController < BaseController
    permit "case.read"

    def index
      @query = ChannelQuery.new(params)
      @rows = @query.rows
      @open_id = params[:open].to_s.presence
    end

    def pane
      query = ChannelQuery.new(params)
      rows = query.rows
      more = (fd_channel_pane_path(query.to_params.merge(page: query.page + 1)) if query.more?)

      render partial: "fd/channels/pane_rows", layout: false,
        locals: { rows: rows, open_id: params[:open].to_s.presence, more: more }
    end
  end
end
