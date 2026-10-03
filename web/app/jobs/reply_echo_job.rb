class ReplyEchoJob < ApplicationJob
  queue_as :default

  def perform(case_id)
    Fd::ReplyEcho.flush_pending(case_id)
  end
end
