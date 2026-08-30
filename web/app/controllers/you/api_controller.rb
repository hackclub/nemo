module You
  class ApiController < BaseController
    def show
      @consents = Api::Consent.states_for(member_id)
      @rooms = SlackScan.channels(member_id)
    end
  end
end
