module You
  class BaseController < ApplicationController
    helper_method :member_id

    private

    def member_id
      current_account.user_id
    end
  end
end
