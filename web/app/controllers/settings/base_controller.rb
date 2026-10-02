module Settings
  class BaseController < ApplicationController
    helper_method :member_id

    private

    def member_id
      current_account.user_id
    end

    def api_off?
      Fd::Flag.off?(:public_api)
    end

    def turned_off
      "#{Fd::Flag.label(:public_api).downcase} is turned off"
    end
  end
end
