module Fd
  class ChatVersion
    Part = Struct.new(:count, :max_id, :stamp) do
      def to_s = "#{count}.#{max_id}.#{stamp}"

      def cutoff = Time.zone.at(stamp / 1000.0)
    end

    SHAPE = /\A(\d+)\.(\d+)\.(\d+)\z/

    CHAT_STAMPS = Arel.sql("count(*), max(id), max(greatest(said_at, edited_at, deleted_at))")
    MESSAGE_STAMPS = Arel.sql("count(*), max(id), max(greatest(posted_at, edited_at, deleted_at))")
    OUTBOX_STAMPS = Arel.sql("count(*), max(id), max(greatest(requested_at, sent_at, failed_at))")
    FILE_STAMPS = Arel.sql(
      "count(*), max(fd.intake_files.id), " \
      "max(greatest(fd.intake_files.first_seen_at, fd.intake_files.last_seen_at, " \
      "fd.intake_files.fetched_at, fd.intake_files.deleted_at))"
    )
    FILES_JOIN = "JOIN fd.intake_message_files mf ON mf.file_id = fd.intake_files.id " \
                 "JOIN fd.intake_messages m ON m.id = mf.message_id"

    SHARE_STAMPS = Arel.sql(
      "count(*), max(fd.intake_shares.id), " \
      "max(greatest(fd.intake_shares.observed_at, fd.intake_shares.last_seen_at))"
    )
    SHARES_JOIN = "JOIN fd.intake_messages m ON m.id = fd.intake_shares.message_id"

    def self.for(case_id)
      parts(case_id).join("-")
    end

    def self.parts(case_id)
      family = Case.family_of(case_id)
      conversations = IntakeConversation.for_case(family).unscope(:order).select(:id)

      [
        part(CaseChat.where(case_id: family), CHAT_STAMPS),
        part(IntakeMessage.where(conversation_id: conversations), MESSAGE_STAMPS),
        part(IntakeOutbox.where(conversation_id: conversations), OUTBOX_STAMPS),
        part(
          IntakeFile.joins(FILES_JOIN)
            .where("m.conversation_id IN (#{conversations.to_sql})"),
          FILE_STAMPS
        ),
        part(
          IntakeShare.joins(SHARES_JOIN)
            .where("m.conversation_id IN (#{conversations.to_sql})"),
          SHARE_STAMPS
        )
      ]
    end

    def self.parse(version)
      pieces = version.to_s.split("-", -1)
      return nil unless pieces.size == 5

      pieces.map do |piece|
        found = piece.match(SHAPE) or return nil
        Part.new(*found.captures.map(&:to_i))
      end
    end

    def self.stamp(*times)
      latest = times.compact.max
      latest ? (latest.to_f * 1000).to_i : 0
    end

    def self.part(rows, stamps)
      count, max_id, latest = rows.pick(stamps)
      Part.new(count, max_id.to_i, stamp(latest))
    end
  end
end
