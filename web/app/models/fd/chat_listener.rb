module Fd
  class ChatListener
    CHANNELS = %w[fd_chat_changed fd_conversation_changed].freeze
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

      CHANNELS.each { |heard| raw.exec("LISTEN #{heard}") }
      Rails.logger.info("chat listener: listening on #{CHANNELS.join(", ")}")

      loop { raw.wait_for_notify(WAIT) { |_channel, _pid, payload| heard(payload) } }
    end

    def heard(payload)
      case_id = self.class.case_id_from(payload)
      return if case_id.nil?

      Rails.application.executor.wrap do
        Fd::ReplyEcho.catch_up(case_id)
        Fd::CaseChatBroadcast.of(case_id)
      end
    rescue StandardError => trouble
      Rails.logger.warn("chat listener: case #{payload}: #{trouble.message}")
    end
  end
end
