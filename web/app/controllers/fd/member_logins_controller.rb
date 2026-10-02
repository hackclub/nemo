module Fd
  class MemberLoginsController < BaseController
    permit "identity.read"

    def show
      user_id = params[:member_id].to_s.upcase
      @sessions = MemberSessions.new(user_id)
      @names = Names.for([user_id] + @sessions.alongside)

      AccessLog.record!(actor: current_account, subject_user_id: user_id,
        field_class: "login")

      render partial: "fd/members/sessions", layout: false,
        locals: { user_id: user_id, sessions: @sessions, names: @names }
    end
  end
end
