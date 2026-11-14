module Fd
  class MemberMentionsController < BaseController
    permit "case.read"

    TS = /\A\d+\.\d+\z/

    def index
      @user_id = params[:member_id].to_s.upcase
      before = parse_time(params[:before])
      @page = MemberMention.page(@user_id, before: before)
      @frame_id = before ? mention_page_frame_id(before) : "member-mentions"
      @names = Names.for(@page.rows.filter_map(&:author_id))
      @channels = ChannelNames.for(@page.rows.map(&:channel_id))
      render layout: false
    end

    def show
      @channel_id = params[:channel_id].to_s.upcase
      @ts = params[:ts].to_s
      return head(:not_found) unless AppSetting.fd_channel_ids.include?(@channel_id) && @ts.match?(TS)

      thread_ts = params[:thread].to_s.presence
      thread_ts = nil unless thread_ts&.match?(TS)
      @slack_message = Slack::Message.at(@channel_id, @ts, thread_ts: thread_ts)
      text = @slack_message.message&.dig("text")
      @names = Names.for(Mentions.ids(text))
      @channels = ChannelNames.for(Mentions.channel_ids(text))
      @emoji = Slack::Emoji.for(Slack::RichText.emoji_names(@slack_message.message))
      render layout: false
    end

    private

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    helper_method def mention_page_frame_id(before)
      "member-mentions-#{before.utc.strftime('%s%6N')}"
    end
  end
end
