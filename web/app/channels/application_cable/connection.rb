module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :user_id

    def connect
      self.user_id = staff_id
      reject_unauthorized_connection unless user_id
    end

    private

    def staff_id
      held = cookies.encrypted["_web_session"]
      held && held["user_id"]
    end
  end
end
