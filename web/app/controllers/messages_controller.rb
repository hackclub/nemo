class MessagesController < ApplicationController
  before_action { needs(:analytics) }
  before_action :require_reading

  def show
    @channel_id = params[:channel_id]
    @ts = params[:ts]
    @channel = Analytics::DimChannel.find_by(channel_id: @channel_id)
    @shown = Channels::Activity.shown?(@channel_id)
    @post = Analytics::FctMessage.post(@channel_id, @ts) if @shown
    return unless @post

    unless may_community?("analytics.message.read", @post)
      return refuse_community("analytics.message.read", @post)
    end

    @said = Slack::Message.at(@channel_id, @ts)
    @names = Fd::Names.for([@post.author_id] + Fd::Mentions.ids(@said.said&.dig("text")))
    @rooms = Analytics::DimChannel
      .where(channel_id: Fd::Mentions.channel_ids(@said.said&.dig("text")))
      .pluck(:channel_id, :name).to_h
    @emoji = Slack::Emoji.for(Slack::RichText.emoji_names(@said.said))
    @crowd = Analytics::FctChannelSpan.where(channel_id: @channel_id).pick(:total_members)
    @span = Messages::Activity::SPANS.key?(params[:span]) ? params[:span] :
      Messages::Activity.span_for(@post.posted_at)
    @activity = @post.is_reply ? nil : Messages::Activity.for(@channel_id, @ts, posted_at: @post.posted_at)
  end
end
