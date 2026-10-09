module Fd
  class AuditsController < BaseController
    permit "case.read"

    around_action :in_viewer_zone

    def show
      @query = AuditQuery.new(params, actor: current_account)
      return redirect_to(fd_audit_path(@query.range_params(params[:start], params[:end]))) if params[:start].present?

      @groups = @query.group ? @query.groups : []
      @rows = @query.group ? [] : @query.rows
      @views = @query.views
      @query.looked_at.each do |field_class, user_ids|
        AccessLog.record_many!(actor: current_account, subject_user_ids: user_ids, field_class: field_class)
      end
      @names = Names.for(named_in(@rows) + grouped("actor"))
      @channels = ChannelNames.for(channel_ids(@rows) + grouped("channel"))
    end

    def histogram
      @query = AuditQuery.new(params, actor: current_account)
      @days = @query.histogram
      render layout: false
    end

    def event
      @query_for_row = AuditQuery.new({}, actor: current_account)
      @row = AuditQuery.one(params[:source].to_s, params[:id].to_s, actor: current_account)
      return head :not_found if @row.nil?
      return head :forbidden unless @query_for_row.may_see?(@row.source)

      @context = AuditContext.new(@row, @query_for_row)
      related = @context.shown_related
      @names = Names.for([@row.actor_id, @row.subject_id, @row.entity_id].compact + named_in(related))
      @channels = ChannelNames.for([@row.entity_ref, @row.entity_id, @row.channel].compact + channel_ids(related))
      render layout: false
    end

    private

    def in_viewer_zone(&)
      Time.use_zone(viewer_zone, &)
    end

    def viewer_zone
      tz = Member.where(user_id: current_account&.user_id).pick(:tz)
      ActiveSupport::TimeZone[tz.to_s] || Time.zone
    end

    def grouped(kind)
      @query.group == kind ? @groups.map(&:key) : []
    end

    def named_in(rows)
      rows.flat_map { |row| [row.actor_id, row.subject_id, member_in(row)] }.compact
    end

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    def member_in(row)
      row.entity_id if row.entity_id.to_s.match?(MEMBER_ID)
    end

    CHANNEL_ID = /\A[CGD][A-Z0-9]{2,}\z/

    def channel_ids(rows)
      rows.flat_map { |row| [row.entity_ref, row.entity_id, row.channel] }
        .select { |one| one.to_s.match?(CHANNEL_ID) }
    end
  end
end
