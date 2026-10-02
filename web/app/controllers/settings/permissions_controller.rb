module Settings
  class PermissionsController < BaseController
    def show
      @apps = Api::App.answering.to_a
      @consents = Api::Consent.states_for(member_id)
      @names = Fd::Names.for(@apps.map(&:owner_user_id).uniq)
    end

    private

    def granted?(app, scope)
      @consents[[app&.id, scope]] == Api::Consent::GRANTED
    end

    def everywhere?(scope) = granted?(nil, scope)

    def covered?(app, scope) = everywhere?(scope) || granted?(app, scope)
    helper_method :granted?, :everywhere?, :covered?
  end
end
