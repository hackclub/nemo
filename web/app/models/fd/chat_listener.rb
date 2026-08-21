module Fd
  class ChatListener
    CHANNEL = "fd_chat_changed"
    LOCK_KEY = 8_314_072
    RETRY_AFTER = 5
    WAIT = 30

    def self.wanted?
      return false if Rails.env.test?

      asked = ENV["NEMO_STREAM"]
      return asked != "0" if asked

      serving?
    end

    def self.serving?
      defined?(Rails::Server) || $PROGRAM_NAME.include?("puma") ||
        $PROGRAM_NAME.include?("thrust")
    end

    def self.start
      new.start
    end

    def self.case_id_from(payload)
      Integer(payload)
    rescue ArgumentError, TypeError
      nil
    end

    def start
      Thread.new { run }
    end

    def run
      loop do
        listen
      rescue StandardError => trouble
        Rails.logger.warn("chat listener: #{trouble.class}: #{trouble.message}")
        sleep RETRY_AFTER
      end
    end

    private

    def listen
      held = ActiveRecord::Base.connection_pool.checkout
      raw = held.raw_connection

      unless mine?(raw)
        Rails.logger.info("chat listener: another process is listening")
        ActiveRecord::Base.connection_pool.checkin(held)
        sleep RETRY_AFTER * 12
        return
      end

      raw.exec("LISTEN #{CHANNEL}")
      Rails.logger.info("chat listener: listening for the bot's messages")
      loop { raw.wait_for_notify(WAIT) { |_channel, _pid, payload| heard(payload) } }
    end

    def mine?(raw)
      raw.exec("SELECT pg_try_advisory_lock(#{LOCK_KEY})").getvalue(0, 0) == "t"
    end

    def heard(payload)
      case_id = self.class.case_id_from(payload)
      return if case_id.nil?

      ActiveRecord::Base.connection_pool.with_connection do
        CaseChatBroadcast.of(case_id)
      end
    rescue StandardError => trouble
      Rails.logger.warn("chat listener: case #{payload}: #{trouble.message}")
    end
  end
end
