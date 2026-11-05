module Fd
  class MembersController < BaseController
    permit "case.read"
    def index
      @layout = params[:layout] == "table" ? "table" : "split"
      @query = MemberQuery.new(params, actor: current_account)
      @rows = @query.rows
      @names = Names.for(@rows.map(&:user_id))
      @context = MemberContext.for(@rows.map(&:user_id))
      @grants = Authz::Grant.live.roles.where(user_id: @rows.map(&:user_id))
        .index_by(&:user_id)
      @views = @query.views
      assign_pane_from_index
    end

    TABS = { "history" => "History", "links" => "Linked accounts", "sessions" => "Sessions",
             "audit" => "Audit", "enforcement" => "Enforcement", "purges" => "Purges" }.freeze
    TAB_CAPABILITIES = { "links" => "member.links", "sessions" => "identity.read",
                         "purges" => "member.purge" }.freeze
    PURGE_ROWS = 50
    AUDIT_ROWS = 60
    AUDIT_SOURCES = "source:slack source:engine".freeze
    CHANNEL_ID = /\A[CGD][A-Z0-9]{2,}\z/

    def show
      @user_id = params[:id].to_s.upcase
      @record = MemberRecord.new(@user_id)
      return show_drawer if turbo_frame_request_id == "person-drawer"

      load_member_pane
      @tabs = TABS.select { |key, _| may_open_tab?(key) }
      @tab = [params[:tab], params[:do]].find { |key| @tabs.key?(key) } || "history"
      load_member_audit if @tab == "audit"
      @guard_history = @tab == "enforcement" ? guard_history : []
      load_purges
      @names = Names.for(@record.referenced_user_ids + @pane_rows.map(&:user_id) + audit_member_ids +
        @guard_history.flat_map(&:referenced_user_ids) + @purges.map(&:asked_by))
      @member = @names.member(@user_id)
      @account = MemberAccount.find_by(user_id: @user_id)
      @entries = MemberTimeline.for(@record, names: @names)
      @identity = MemberIdentity.look_up(@user_id, actor: current_account)
      @context = MemberContext.for([@user_id])[@user_id]
      @member_channels = SlackScan.channels(@user_id)
      @standing = MemberStanding.new(@record)
      @guards = @standing.in_force
      @scheduled_guards = @record.scheduled_guards
      @channels = ChannelNames.for(@guards.map(&:channel_id) + @guard_history.map(&:channel_id) +
        audit_channel_ids + @purges.filter_map(&:channel_id))
      @member_grant = @pane_grants[@user_id] || Authz::Grant.live.roles.find_by(user_id: @user_id)
      return unless current_account.may?("member.links")

      @member_links = MemberLink.link_counts_for(@user_id)
      @cluster = MemberLink.cluster_for(@user_id)
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
        open_id: params[:open].to_s.presence, more: more, query_params: query.to_params
      }
    end

    def search
      ids = MemberFinder.new(params[:q], actor: current_account).suggest(limit: Member::LIMIT,
        case_id: params[:case_id].presence&.to_i, bots: params[:bots].present?)

      names = Names.for(ids)
      members = ids.map do |id|
        member = names.member(id)
        { id: id, name: names[id], handle: member&.handle.presence,
          initial: names.initial(id), deleted: member&.is_deleted || false }
      end

      render json: { members: members }
    end

    private

    def load_purges
      return @purges = [] unless @tabs.key?("purges")

      member_purges = ChannelPurge.where(member_id: @user_id).confirmed
      @purge_count = member_purges.count
      @purges = @tab == "purges" ? member_purges.includes(:items).newest_first.limit(PURGE_ROWS).to_a : []
    end

    def may_open_tab?(key)
      capability = TAB_CAPABILITIES[key]
      capability.nil? || current_account.may?(capability)
    end

    def load_member_audit
      @audit_params = { "view" => "everything", AuditQuery::TERM_KEY => "about:#{@user_id} #{AUDIT_SOURCES}" }
      @audit_query = AuditQuery.new(@audit_params, actor: current_account)
      @audit_rows = @audit_query.rows.first(AUDIT_ROWS)
      record_audit_reads(@audit_query)
    end

    def audit_member_ids
      Array(@audit_rows).flat_map { |row| [row.actor_id, row.subject_id] }.compact
    end

    def audit_channel_ids
      Array(@audit_rows).flat_map { |row| [row.entity_ref, row.entity_id, row.channel] }
        .grep(CHANNEL_ID)
    end

    def guard_history
      MemberGuard.for_subject(@user_id).order(opened_at: :desc, id: :desc).to_a
    end

    def show_drawer
      @names = Names.for(@record.referenced_user_ids + [@user_id])
      @member = @names.member(@user_id)
      @context = MemberContext.for([@user_id])[@user_id]
      @member_channels = SlackScan.channels(@user_id)
      @standing = MemberStanding.new(@record)
      @guards = @standing.in_force
      @channels = ChannelNames.for(@guards.map(&:channel_id))
      render "drawer"
    end

    def assign_pane_from_index
      @pane_query = @query
      @pane_rows = @rows
      @pane_context = @context
      @pane_grants = @grants
      @pane_views = @views
    end

    def load_member_pane
      query_params = params.to_unsafe_h.slice(*MemberQuery::KEYS, "q")
      @pane_query = MemberQuery.new(query_params, actor: current_account)
      @pane_params = @pane_query.to_params
      @pane_rows = @pane_query.rows
      user_ids = @pane_rows.map(&:user_id)
      @pane_context = MemberContext.for(user_ids)
      @pane_grants = Authz::Grant.live.roles.where(user_id: user_ids).index_by(&:user_id)
      @pane_views = @pane_query.views
    end
  end
end
