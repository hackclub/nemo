module Fd
  class AuditsController < BaseController
    permit "case.read"

    def show
      @query = AuditQuery.new(params, actor: current_account)
      return redirect_to(fd_audit_path(@query.range_params(params[:start], params[:end]))) if params[:start].present?

      @rows = @query.rows
      @views = @query.views
      @names = Names.for(named_in(@rows))
      @channels = ChannelNames.for(channel_ids(@rows))
    end

    def event
      @query_for_row = AuditQuery.new({}, actor: current_account)
      @row = AuditQuery.one(params[:source].to_s, params[:id].to_s)
      return head :not_found if @row.nil?
      return head :forbidden unless @query_for_row.may_see?(@row.source)

      @names = Names.for([@row.actor_id, @row.subject_id, @row.entity_id].compact)
      @channels = ChannelNames.for([@row.entity_ref, @row.entity_id].compact)
      render layout: false
    end

    private

    def named_in(rows)
      rows.flat_map { |row| [row.actor_id, row.subject_id, member_in(row)] }.compact
    end

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    def member_in(row)
      row.entity_id if row.entity_id.to_s.match?(MEMBER_ID)
    end

    CHANNEL_ID = /\A[CGD][A-Z0-9]{2,}\z/

    def channel_ids(rows)
      rows.flat_map { |row| [row.entity_ref, row.entity_id] }
        .select { |one| one.to_s.match?(CHANNEL_ID) }
    end
  end
end
