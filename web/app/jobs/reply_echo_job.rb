class ReplyEchoJob < ApplicationJob
  queue_as :default

  def perform(case_id)
    Fd::ReplyEcho.catch_up(case_id)
  rescue StandardError => e
    Rails.logger.error("reply echo failed for case #{case_id}: #{e.message}")
  end
end
