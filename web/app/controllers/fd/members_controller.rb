module Fd
  class MembersController < BaseController
    def search
      found = Member.search(params[:q]).map do |member|
        { id: member.user_id, name: member.name, handle: member.handle,
          initial: member.initial, deleted: member.is_deleted }
      end

      render json: { members: found }
    end
  end
end
