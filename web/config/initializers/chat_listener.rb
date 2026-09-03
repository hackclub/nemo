Rails.application.config.after_initialize do
  unless Fd::ChatListener.wanted? || Rails.env.test?
    Rails.logger.info(
      "chat listener: not started, so the case chat only updates on a reload. " \
      "set NEMO_STREAM=1 to stream it"
    )
  end
end
