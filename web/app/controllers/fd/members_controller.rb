module Fd
  class MembersController < BaseController
    def show
      @user_id = params[:id].to_s.upcase
      @record = MemberRecord.new(@user_id)
      @names = Names.for(@record.people_named)
      @member = @names.member(@user_id)
      @only = MemberTimeline::KINDS.key?(params[:show]) ? params[:show] : "all"
      @history = MemberTimeline.for(@record, names: @names, only: @only)
      @identity = MemberIdentity.look_up(@user_id, actor: current_staff)
      @context = MemberContext.for([@user_id])[@user_id]
    end

    def search
      found = Member.search(params[:q]).map do |member|
        { id: member.user_id, name: member.name, handle: member.handle,
          initial: member.initial, deleted: member.is_deleted }
      end

      render json: { members: found }
    end
  end
end
