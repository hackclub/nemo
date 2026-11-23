Rails.application.config.session_store :cookie_store,
  key: "_web_session",
  expire_after: 1.month
