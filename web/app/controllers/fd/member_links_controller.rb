module Fd
  class MemberLinksController < BaseController
    permit "member.links"

    LIMIT = 100
    VIEWS = { "review" => "Needs review", "clusters" => "Clusters", "pairs" => "All pairs" }.freeze
    DEFAULT_VIEW = "review".freeze

    def index
      @view = VIEWS.key?(params[:view]) ? params[:view] : DEFAULT_VIEW
      @names = Names.for(send("#{@view}_ids"))
    end

    private

    def review_ids
      @pairs = MemberLink.needs_review(limit: LIMIT)
      @pairs.flat_map { |one| [one.active_id, one.deactivated_id] }
    end

    def clusters_ids
      @clusters = MemberLink.clusters(limit: LIMIT)
      @clusters.map(&:cluster_id)
    end

    def pairs_ids
      @links = MemberLink.strongest(limit: LIMIT, over: over)
      @links.flat_map { |one| [one.a_user_id, one.b_user_id] }
    end

    def over
      asked = params[:over].to_s
      return MemberLink::CERTAIN if asked == "certain"
      return MemberLink::STRONG if asked == "strong"

      nil
    end
  end
end
