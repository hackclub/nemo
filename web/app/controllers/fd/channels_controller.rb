module Fd
  class ChannelsController < BaseController
    permit "case.read"

    def index
      @query = ChannelQuery.new(params)
      @rows = @query.rows
      @open_id = params[:open].to_s.presence
      @guards_on = LiveGuards.new(params[:kind])
      @channels = @guards_on.channels
      @names = Names.for(@guards_on.opener_user_ids)
    end

    ACTIVITY_LIMIT = 50
    PICKER_LIMIT = 40
    SPAN = "LEFT JOIN analytics.fct_channel_span s " \
           "ON s.channel_id = dim_channel.channel_id".freeze

    def search
      term = params[:q].to_s.strip.delete_prefix("#")
      scope = Analytics::DimChannel.where(archived: false)
      if term.present?
        like = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
        scope = scope.where("dim_channel.name ILIKE :like OR " \
                            "dim_channel.channel_id ILIKE :like", like: like)
      end

      render json: {
        channels: scope.joins(SPAN)
          .order(Arel.sql("s.total_members DESC NULLS LAST, dim_channel.name"))
          .limit(PICKER_LIMIT).pluck(:channel_id, :name)
          .map { |id, name| { id: id, name: name } },
        total: scope.count
      }
    end

    TABS = %w[overview bots readonly slowmode account_age purge].freeze

    TAB_KINDS = {
      "bots" => ChannelGuard::BOT_ALLOWLIST,
      "readonly" => ChannelGuard::READONLY,
      "slowmode" => ChannelGuard::SLOWMODE,
      "account_age" => ChannelGuard::ACCOUNT_AGE
    }.freeze

    KIND_TABS = TAB_KINDS.invert.freeze

    def show
      @channel_id = params[:channel_id].to_s.strip.upcase
      @tab = params[:tab].presence_in(TABS) || TABS.first
      @channel = Analytics::DimChannel.find_by(channel_id: @channel_id)
      @guards = ChannelGuard.live_by_kind(@channel_id)
      @guard = @guards[ChannelGuard::BOT_ALLOWLIST]
      @kind = TAB_KINDS[@tab]
      @kind_guard = @kind ? @guards[@kind] : nil
      @allows = @kind_guard ? @kind_guard.allows.oldest_first.to_a : []
      @thread_slowmodes = @tab == "slowmode" ? ChannelGuard.thread_slowmodes(@channel_id).to_a : []
      @thread_locks = @tab == "overview" ? ThreadGuard.active.locks.where(channel_id: @channel_id)
        .newest_first.to_a : []
      @standing = ChannelJoin.latest_for(@channel_id)
      @nemo_inside = ChannelMembership.inside?(@channel_id)
      @events = @kind ? ChannelGuardEvent.for_kind(@channel_id, @kind)
        .newest_first.limit(ACTIVITY_LIMIT).to_a : []
      @purges = @tab == "purge" ? ChannelPurge.for_channel(@channel_id).confirmed.includes(:items)
        .newest_first.limit(ACTIVITY_LIMIT).to_a : []
      @labels = labels_for(@events)
      @app_ids = app_ids_for(@allows)
      @names = Names.for([@guards.values.flat_map(&:referenced_user_ids),
                          @thread_slowmodes.map(&:opened_by), @thread_locks.map(&:opened_by),
                          @allows.map(&:subject_id), @events.map(&:subject_id),
                          @purges.flat_map(&:referenced_user_ids)])
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

      allow_labels = ChannelGuardAllow.where(subject_id: ids).where.not(label: nil)
        .pluck(:subject_id, :label).to_h
      member_names = Member.where(user_id: ids).to_h { |member| [member.user_id, member.name] }
      member_names.merge(allow_labels)
    end

    def load_pane
      @query = ChannelQuery.new(params.to_unsafe_h.slice("q"))
      @rows = @query.rows
      @open_id = @channel_id
    end
  end
end
