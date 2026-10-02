module Channels
  class Pulse
    MEASURES = %i[
      messages member_messages bot_messages thread_replies thread_roots replies_on_roots
      questions questions_with_replies with_link with_file emoji_only substantive
      with_mention reactions unreacted text_length_total
    ].freeze

    Day = Struct.new(:ds, :member_messages, :bot_messages, :authors, :thread_roots, :reactions,
      keyword_init: true)

    attr_reader :from, :to, :days

    def self.edge
      Analytics::MartChannelDay.maximum(:ds)
    end

    def self.for(channel_id, from:, to:)
      new(channel_id: channel_id, from: from, to: to)
    end

    def initialize(channel_id:, from:, to:, rows: nil)
      @channel_id = channel_id
      @from = from
      @to = to
      @days = (to - from).to_i + 1
      @rows = rows
    end

    def rows
      @rows ||= Analytics::MartChannelDay
        .where(channel_id: @channel_id, ds: @from..@to)
        .order(:ds)
        .to_a
    end

    def any?
      rows.any?
    end

    MEASURES.each do |name|
      define_method(name) { total(name) }
    end

    def total(measure)
      totals.fetch(measure.to_sym, 0)
    end

    def totals
      @totals ||= MEASURES.index_with { |name| rows.sum { |row| row.public_send(name).to_i } }
    end

    def posters_per_day
      return nil if rows.empty?

      (rows.sum { |row| row.authors.to_i }.to_f / rows.size).round
    end

    def posters_change
      was = prior.posters_per_day
      now = posters_per_day
      return nil if was.nil? || now.nil? || was.zero?

      ((now - was) * 100.0 / was).round(1)
    end

    def busiest_day
      rows.max_by { |row| row.member_messages.to_i }
    end

    def prior
      @prior ||= self.class.new(channel_id: @channel_id, from: @from - @days, to: @from - 1)
    end

    def change(measure)
      was = prior.total(measure)
      return nil if was.zero?

      ((total(measure) - was) * 100.0 / was).round(1)
    end

    def share(part, whole)
      part, whole = total(part), total(whole) if part.is_a?(Symbol) && whole.is_a?(Symbol)
      return nil if whole.to_i.zero?

      (part.to_f / whole * 100).round(1)
    end

    def answered_share
      share(:questions_with_replies, :questions)
    end

    def threaded_share
      share(:thread_replies, :messages)
    end

    def replies_per_thread
      roots = total(:thread_roots)
      return nil if roots.zero?

      (total(:replies_on_roots).to_f / roots).round(1)
    end

    def unreacted_share
      share(:unreacted, :messages)
    end

    def average_length
      count = total(:messages)
      return nil if count.zero?

      (total(:text_length_total).to_f / count).round
    end

    def bot_share
      share(:bot_messages, :messages)
    end

    def series
      @series ||= begin
        held = rows.index_by(&:ds)
        (@from..@to).map do |ds|
          row = held[ds]
          Day.new(ds: ds,
            member_messages: row&.member_messages.to_i,
            bot_messages: row&.bot_messages.to_i,
            authors: row&.authors.to_i,
            thread_roots: row&.thread_roots.to_i,
            reactions: row&.reactions.to_i)
        end
      end
    end

    def labels
      series.map { |day| day.ds.iso8601 }
    end

    def share_series(measure)
      held = rows.index_by(&:ds)
      (@from..@to).map do |ds|
        row = held[ds]
        said = row&.messages.to_i
        next nil if said.zero?

        (row.public_send(measure).to_i * 100.0 / said).round(1)
      end
    end
  end
end
