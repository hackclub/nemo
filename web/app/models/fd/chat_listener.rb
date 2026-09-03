module Fd
  class ChatListener
    CHANNELS = %w[fd_chat_changed fd_conversation_changed].freeze
    RETRY_AFTER = 5
    WAIT = 30
    OFF = %w[0 false no off].freeze

    def self.wanted?
      return false if Rails.env.test?

      asked = ENV["NEMO_STREAM"].presence
      return OFF.exclude?(asked.downcase) if asked

      serving?
    end

    def self.serving?
      defined?(Rails::Server) || $PROGRAM_NAME.include?("puma") ||
        $PROGRAM_NAME.include?("thrust")
    end

    def self.start
      new.start
    end

    def self.connection_options(config = ActiveRecord::Base.connection_db_config.configuration_hash)
      {
        host: config[:host],
        port: config[:port],
        dbname: config[:database],
        user: config[:username],
        password: config[:password]
      }.compact
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

    def listen(raw = PG.connect(self.class.connection_options))
      CHANNELS.each { |heard| raw.exec("LISTEN #{heard}") }
      Rails.logger.info("chat listener: listening on #{CHANNELS.join(", ")}")

      loop { raw.wait_for_notify(WAIT) { |_channel, _pid, payload| heard(payload) } }
    ensure
      raw&.close
    end

    def heard(payload)
      case_id = self.class.case_id_from(payload)
      return if case_id.nil?

      Rails.application.executor.wrap do
        Fd::CaseChatBroadcast.of(case_id)
        ReplyEchoJob.perform_later(case_id)
      end
    rescue StandardError => trouble
      Rails.logger.warn("chat listener: case #{payload}: #{trouble.message}")
    end
  end
end
