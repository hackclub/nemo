module Fd
  class ChannelPurge < ApplicationRecord
    self.table_name = "fd.channel_purges"

    ASKED = "asked".freeze
    RUNNING = "running".freeze
    DONE = "done".freeze
    FAILED = "failed".freeze

    WAITING = [ASKED, RUNNING].freeze
    MOST = 100

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, optional: true,
      inverse_of: false

    scope :waiting, -> { where(state: WAITING) }
    scope :newest_first, -> { order(asked_at: :desc, id: :desc) }
    scope :for_channel, ->(channel_id) { where(channel_id: channel_id) }

    def self.waiting_on?(channel_id)
      waiting.for_channel(channel_id).exists?
    end

    def waiting? = WAITING.include?(state)
    def done? = state == DONE
    def failed? = state == FAILED

    def kept
      transcript.is_a?(Array) ? transcript : []
    end

    def replies_taken
      kept.count { |one| one["thread_ts"].present? }
    end

    Said = Struct.new(:ts, :thread_ts, :user, :text, keyword_init: true) do
      def at
        Time.zone.at(ts.to_f) if ts.to_s.include?(".")
      end
    end

    class Reading
      def initialize(kept)
        @said = kept.map { |one| Said.new(**one.symbolize_keys.slice(*Said.members)) }
      end

      def tops
        @tops ||= @said.reject { |one| one.thread_ts.present? }.sort_by { |one| one.ts.to_f }
      end

      def below(parent)
        replies.fetch(parent.ts, [])
      end

      def orphans
        @orphans ||= replies.reject { |ts, _| tops.any? { |one| one.ts == ts } }.values.flatten
      end

      def any? = @said.any?

      private

      def replies
        @replies ||= @said.select { |one| one.thread_ts.present? }
          .group_by(&:thread_ts)
          .transform_values { |held| held.sort_by { |one| one.ts.to_f } }
      end
    end

    def people_named
      [asked_by] + kept.filter_map { |one| one["user"] }
    end
  end
end
