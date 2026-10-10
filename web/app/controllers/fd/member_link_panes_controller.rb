module Fd
  class MemberLinkPanesController < BaseController
    permit "member.links"

    def show
      user_id = params[:member_id].to_s.upcase
      links = MemberLink.for_member(user_id)
      mates = MemberLink.cluster_mates(user_id, except: links.map(&:other_id))
      verdicts = LinkVerdict.for_pairs(links.map { |one| [user_id, one.other_id] })
      shown = mates.first(MemberLink::MATES_SHOWN)
      names = Names.for([user_id] + links.map(&:other_id) + shown + verdicts.values.map(&:decided_by))
      @names = names

      AccessLog.record!(actor: current_account, subject_user_id: user_id,
        field_class: "links")

      render partial: "fd/members/links", layout: false,
        locals: { user_id: user_id, links: links, mates: mates, names: names, verdicts: verdicts,
                  cluster_of: MemberLink.cluster_of(user_id) }
    end
  end
end
