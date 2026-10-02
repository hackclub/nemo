class CaseChatPresenceChannel < ApplicationCable::Channel
  def subscribed
    kase = Fd::Case.find_by(id: params[:case_id])
    account = Account.find_by(user_id: user_id)
    return reject unless kase && account && Fd::Access.allow?(account, "case.read", kase)

    @case_id = kase.id
    Fd::ChatPresence.arrive(@case_id, user_id)
  end

  def beat
    Fd::ChatPresence.beat(@case_id, user_id) if @case_id
  end

  def unsubscribed
    Fd::ChatPresence.leave(@case_id, user_id) if @case_id
  end
end
