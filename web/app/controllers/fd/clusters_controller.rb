module Fd
  class ClustersController < BaseController
    permit "member.links"

    def show
      @cluster = ClusterView.find(params[:id])
      return head :not_found if @cluster.nil?

      @identity = current_account.may?("identity.read")
      AccessLog.record_many!(actor: current_account, subject_user_ids: @cluster.ids, field_class: "links")
      AccessLog.record_many!(actor: current_account, subject_user_ids: @cluster.ids, field_class: "login") if @identity
      @names = Names.for(@cluster.ids + @cluster.snapshots.filter_map(&:actor_id))
    end
  end
end
