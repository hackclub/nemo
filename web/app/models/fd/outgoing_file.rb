module Fd
  class OutgoingFile
    ON_ITS_WAY = "sending".freeze

    def self.queued_on(row)
      Array(row.files).map { |held| new(held) }
    end

    def initialize(held)
      @held = held || {}
    end

    def shown_name
      @held["name"].presence || "attachment"
    end

    def said
      ON_ITS_WAY
    end

    def kept?
      false
    end

    def image?
      false
    end
  end
end
