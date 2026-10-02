class ReplyEchoJob < ApplicationJob
  queue_as :default

  def perform(case_id)
    Fd::ReplyEcho.catch_up(case_id)
  end
end
