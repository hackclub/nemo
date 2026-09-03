module Fd
  class ChatVersion
    Part = Struct.new(:count, :max_id, :stamp) do
      def to_s = "#{count}.#{max_id}.#{stamp}"

      def cutoff = Time.zone.at(stamp / 1000.0)
    end

    SHAPE = /\A(\d+)\.(\d+)\.(\d+)\z/

    def self.for(case_id)
      parts(case_id).join("-")
    end

    def self.parts(case_id)
      family = Case.family_of(case_id)
      conversations = IntakeConversation.for_case(family).unscope(:order).select(:id)

      [
        part(CaseChat.where(case_id: family), "said_at, edited_at, deleted_at"),
        part(IntakeMessage.where(conversation_id: conversations), "posted_at, edited_at, deleted_at"),
        part(IntakeOutbox.where(conversation_id: conversations), "requested_at, sent_at, failed_at")
      ]
    end

    def self.parse(version)
      pieces = version.to_s.split("-", -1)
      return nil unless pieces.size == 3

      pieces.map do |piece|
        found = piece.match(SHAPE) or return nil
        Part.new(*found.captures.map(&:to_i))
      end
    end

    def self.stamp(*times)
      latest = times.compact.max
      latest ? (latest.to_f * 1000).to_i : 0
    end

    def self.part(rows, columns)
      count, max_id, latest = rows.pick(Arel.sql("count(*), max(id), max(greatest(#{columns}))"))
      Part.new(count, max_id.to_i, stamp(latest))
    end
  end
end
