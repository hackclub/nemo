module Channels
  class Welcome
    Step = Struct.new(:key, :label, :count, :share, :lost, keyword_init: true)

    attr_reader :row

    def self.for(channel_id)
      new(Analytics::MartChannelNewcomers.find_by(channel_id: channel_id), channel_id)
    end

    def initialize(row, channel_id)
      @row = row
      @channel_id = channel_id
    end

    def any?
      row.present? && row.newcomers.to_i.positive?
    end

    def newcomers = row&.newcomers.to_i
    def window_start = row&.window_start
    def window_end = row&.window_end

    def funnel
      return [] unless any?

      answered = row.answered_by_member.to_i
      fast = row.answered_fast.to_i

      [
        Step.new(key: "landed", label: "posted here first", count: newcomers,
          share: 100.0, lost: nil),
        Step.new(key: "answered", label: "a human replied", count: answered,
          share: pct(answered, newcomers), lost: newcomers - answered),
        Step.new(key: "fast", label: "replied to inside #{fast_label}", count: fast,
          share: pct(fast, newcomers), lost: answered - fast)
      ]
    end

    def returned
      measured = row&.measured_day_30.to_i
      return nil unless measured.positive?

      Step.new(key: "returned", label: "posted again within 30 days",
        count: row.returned_day_30.to_i, share: pct(row.returned_day_30.to_i, measured),
        lost: measured - row.returned_day_30.to_i)
    end

    def median_latency
      row&.median_latency_seconds
    end

    def returned_share
      row&.returned_share&.to_f&.*(100)&.round(1)
    end

    def answered_share
      row&.answered_share&.to_f&.*(100)&.round(1)
    end

    def latency
      @latency ||= Analytics::MartChannelReplyLatency
        .where(channel_id: @channel_id).order(:bucket_order).to_a
    end

    def fast_label
      seconds = row&.fast_reply_seconds.to_i
      return "an hour" if seconds == 3600
      return "#{seconds / 60} min" if seconds < 3600

      "#{seconds / 3600}h"
    end

    private

    def pct(part, whole)
      return nil if whole.to_i.zero?

      (part * 100.0 / whole).round(1)
    end
  end
end
