module Fd
  class MembersController < BaseController
    permit "case.read"
    def index
      @layout = params[:layout] == "table" ? "table" : "split"
      @query = MemberQuery.new(params, actor: current_account)
      @rows = @query.rows
      log_identity_search
      @names = Names.for(@rows.map(&:user_id))
      @context = MemberContext.for(@rows.map(&:user_id))
      @grants = Authz::Grant.live.roles.where(user_id: @rows.map(&:user_id))
        .index_by(&:user_id)
      @views = @query.views
      assign_pane_from_index
    end

    def show
      @user_id = params[:id].to_s.upcase
      @record = MemberRecord.new(@user_id)
      load_member_pane
      @names = Names.for(@record.people_named + @pane_rows.map(&:user_id))
      @member = @names.member(@user_id)
      @only = MemberTimeline::TABS.key?(params[:show]) ? params[:show] : "all"
      @entries = MemberTimeline.for(@record, names: @names)
      @counts = @entries.group_by(&:kind).transform_values(&:size)
      @counts["all"] = @entries.size
      @history = @only == "all" ? @entries : @entries.select { |entry| entry.kind == @only }
      @identity = MemberIdentity.look_up(@user_id, actor: current_account)
      @context = MemberContext.for([@user_id])[@user_id]
      @rooms = SlackScan.channels(@user_id)
      @standing = MemberStanding.new(@record)
      @member_grant = @pane_grants[@user_id] || Authz::Grant.live.roles.find_by(user_id: @user_id)
      render "drawer" if turbo_frame_request_id == "person-drawer"
    end

    def pane
      query = MemberQuery.new(params, actor: current_account)
      rows = query.rows
      ids = rows.map(&:user_id)
      @names = Names.for(ids)
      more = if query.pages > query.page
        fd_member_pane_path(query.page_params(query.page + 1).merge({ open: params[:open].presence }.compact))
      end

      render partial: "fd/members/pane_rows", layout: false, locals: {
        rows: rows, context: MemberContext.for(ids),
        grants: Authz::Grant.live.roles.where(user_id: ids).index_by(&:user_id),
        open_id: params[:open].to_s.presence, more: more, carry: query.to_params
      }
    end

    def search
      term = params[:q].to_s.strip
      query = MemberQuery.new({ "q" => term }, actor: current_account)
      results = term.length >= Member::MIN_TERM ? query.rows.first(Member::LIMIT) : []
      if results.empty? && term.match?(Member::MEMBER_ID)
        results = Member.where(user_id: term.delete_prefix("@").upcase).to_a
      end
      log_identity_picker_hits(results) if identity_search?(term)

      faces = Names.for(results.map(&:user_id))
      found = results.map do |row|
        member = faces.member(row.user_id)
        { id: row.user_id, name: faces[row.user_id], handle: member&.handle.presence,
          initial: faces.initial(row.user_id), deleted: member&.is_deleted || false }
      end

      render json: { members: found }
    end

    private

    def assign_pane_from_index
      @pane_query = @query
      @pane_rows = @rows
      @pane_context = @context
      @pane_grants = @grants
      @pane_views = @views
    end

    def load_member_pane
      carried = params.to_unsafe_h.slice(*MemberQuery::KEYS, "q")
      @pane_query = MemberQuery.new(carried, actor: current_account)
      @pane_params = @pane_query.to_params
      @pane_rows = @pane_query.rows
      user_ids = @pane_rows.map(&:user_id)
      @pane_context = MemberContext.for(user_ids)
      @pane_grants = Authz::Grant.live.roles.where(user_id: user_ids).index_by(&:user_id)
      @pane_views = @pane_query.views
    end

    def log_identity_search
      return unless @query.looked_up_identity?

      @rows.each do |row|
        AccessLog.record!(actor: current_account, subject_user_id: row.user_id,
          field_class: "identity_search")
      end
    end

    def identity_search?(term)
      term.to_s.strip.present? && current_account.may?("identity.read")
    end

    def log_identity_picker_hits(results)
      results.each do |member|
        AccessLog.record!(actor: current_account, subject_user_id: member.user_id,
          field_class: "identity_search")
      end
    end
  end
end
