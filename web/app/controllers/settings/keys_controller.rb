module Settings
  class KeysController < BaseController
    def show
      load_keys
    end

    private

    def load_keys
      @apps = Api::App.for_owner(member_id).to_a
      @approved = Api::Approval.live.where(app_id: @apps.map(&:id)).pluck(:app_id).to_set
      @waiting = Api::AccessRequest.pending.where(app_id: @apps.map(&:id))
        .index_by(&:app_id)
      @tokens = Api::Token.where(app_id: @apps.map(&:id))
        .order(revoked_at: :asc, created_at: :desc).group_by(&:app_id)
      @cap = Api::Setting.value("tokens_per_owner")
    end

    def approved?(app) = @approved.include?(app.id)

    def waiting_for(app) = @waiting[app.id]

    def tokens_for(app) = @tokens.fetch(app.id, [])
    helper_method :approved?, :waiting_for, :tokens_for
  end
end
