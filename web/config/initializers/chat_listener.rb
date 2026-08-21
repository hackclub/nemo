Rails.application.config.after_initialize do
  Fd::ChatListener.start if Fd::ChatListener.wanted?
end
