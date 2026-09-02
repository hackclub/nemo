module Fd
  class MembersController < BaseController
    permit "case.read"
    def index
      @query = MemberQuery.new(params, actor: current_staff)
      @rows = @query.rows
      log_identity_search
      @names = Names.for(@rows.map(&:user_id))
      @context = MemberContext.for(@rows.map(&:user_id))
      @grants = AccessGrant.where(user_id: @rows.map(&:user_id), revoked_at: nil)
        .index_by(&:user_id)
      @views = @query.views
    end

    def show
      @user_id = params[:id].to_s.upcase
      @record = MemberRecord.new(@user_id)
      @names = Names.for(@record.people_named)
      @member = @names.member(@user_id)
      @only = MemberTimeline::TABS.key?(params[:show]) ? params[:show] : "all"
      @entries = MemberTimeline.for(@record, names: @names)
      @counts = @entries.group_by(&:kind).transform_values(&:size)
      @counts["all"] = @entries.size
      @history = @only == "all" ? @entries : @entries.select { |entry| entry.kind == @only }
      @identity = MemberIdentity.look_up(@user_id, actor: current_staff)
      @context = MemberContext.for([@user_id])[@user_id]
      @rooms = SlackScan.channels(@user_id)
      @standing = MemberStanding.new(@record)
      render "drawer" if turbo_frame_request_id == "person-drawer"
    end

    def search
      found = Member.search(params[:q]).map do |member|
        { id: member.user_id, name: member.name, handle: member.handle,
          initial: member.initial, deleted: member.is_deleted }
      end

      render json: { members: found }
    end

    private

    def log_identity_search
      return unless @query.looked_up_identity?

      @rows.each do |row|
        AccessLog.record!(actor: current_staff, subject_user_id: row.user_id,
          field_class: "identity_search")
      end
    end
  end
end
