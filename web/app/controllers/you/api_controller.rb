module You
  class ApiController < BaseController
    TABS = { "permissions" => "Permissions", "tokens" => "Tokens" }.freeze

    def show
      @tab = TABS.key?(params[:tab]) ? params[:tab] : "permissions"
      @consents = Api::Consent.states_for(member_id)
      @tokens = Api::Token.for_owner(member_id)
      @rooms = SlackScan.channels(member_id)
    end
  end
end
