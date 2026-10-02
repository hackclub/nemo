module Fd
  class MemberLinkPanesController < BaseController
    permit "member.links"

    def show
      user_id = params[:member_id].to_s.upcase
      links = MemberLink.for_member(user_id)
      names = Names.for([user_id] + links.map(&:other_id))

      AccessLog.record!(actor: current_account, subject_user_id: user_id,
        field_class: "links")

      render partial: "fd/members/links", layout: false,
        locals: { user_id: user_id, links: links, names: names }
    end
  end
end
