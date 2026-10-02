module Fd
  class MemberLinksController < BaseController
    permit "member.links"

    LIMIT = 100

    def index
      @links = MemberLink.strongest(limit: LIMIT, over: over)
      @names = Names.for(@links.flat_map { |one| [one.a_user_id, one.b_user_id] })
    end

    private

    def over
      asked = params[:over].to_s
      return MemberLink::CERTAIN if asked == "certain"
      return MemberLink::STRONG if asked == "strong"

      nil
    end
  end
end
