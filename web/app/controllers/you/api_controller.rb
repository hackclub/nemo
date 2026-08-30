module You
  class ApiController < BaseController
    def show
      @rooms = SlackScan.channels(member_id)
    end
  end
end
