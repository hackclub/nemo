class MessageFilesController < ApplicationController
  before_action { needs(:analytics) }
  before_action :require_reading

  CACHE = "private, max-age=300".freeze
  LOCKED_DOWN = "default-src 'none'; sandbox".freeze

  def show
    channel_id = params[:channel_id]
    ts = params[:ts]
    return head :not_found unless Channels::Activity.shown?(channel_id)

    post = Analytics::FctMessage.post(channel_id, ts)
    return head :not_found if post.nil?
    return head :forbidden unless may_community?("analytics.message.read", post)

    said = Slack::Message.at(channel_id, ts)
    one = Messages::File.in(said.said, params[:file_id])
    return head :not_found if one.nil? || one["url_private"].blank?

    hand_over(one)
  end

  private

  def hand_over(one)
    found = Messages::File.bytes_of(one)
    return head :bad_gateway if found.error

    response.headers["Cache-Control"] = CACHE
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Content-Security-Policy"] = LOCKED_DOWN
    send_data found.bytes, type: found.kind, filename: found.name.presence || params[:file_id],
      disposition: Messages::File.image?(one) ? "inline" : "attachment"
  end
end
