module Channels
  class Crowd
    SHOWN = 10
    MONTHS_OFFERED = 12

    TENURE = {
      "under_90d" => "under 90 days",
      "under_1y" => "90 days to a year",
      "under_3y" => "one to three years",
      "over_3y" => "over three years",
      "unknown" => "join date unknown"
    }.freeze

    TENURE_ORDER = TENURE.keys.freeze

    Slice = Struct.new(:key, :label, :people, :messages, :share, keyword_init: true)
    Part = Struct.new(:key, :label, :people, :share, keyword_init: true)

    attr_reader :channel_id, :month

    def self.for(channel_id, month: nil)
      new(channel_id, month: month)
    end

    def initialize(channel_id, month: nil)
      @channel_id = channel_id
      @month = months.include?(month) ? month : months.first
    end

    def months
      @months ||= Analytics::MartChannelPerson
        .where(channel_id: channel_id)
        .distinct.order(month: :desc).limit(MONTHS_OFFERED).pluck(:month)
    end

    def any?
      month.present?
    end

    def people
      @people ||= Analytics::MartChannelPerson.where(channel_id: channel_id, month: month)
    end

    def head
      @head ||= people.order(:channel_rank).first
    end

    def posters = head&.channel_posters.to_i
    def messages = head&.channel_messages.to_i
    def month_end = head&.month_end

    def top(limit: SHOWN)
      @top ||= {}
      @top[limit] ||= people.order(:channel_rank).limit(limit).to_a
    end

    def tenure
      @tenure ||= begin
        counted = people.group(:tenure_band)
          .pluck(Arel.sql("tenure_band, count(*), coalesce(sum(messages), 0)"))
          .to_h { |band, folk, said| [band, [folk.to_i, said.to_i]] }
        whole = counted.values.sum { |_, said| said }

        TENURE_ORDER.filter_map do |band|
          folk, said = counted[band]
          next if folk.nil? || said.to_i.zero?

          Slice.new(key: band, label: TENURE.fetch(band), people: folk, messages: said,
            share: whole.positive? ? (said * 100.0 / whole).round(1) : nil)
        end
      end
    end

    def composition(range)
      return [] if range.nil?

      members = range.total_members.to_i
      return [] unless members.positive?

      spoke = range.members_who_posted.to_i.clamp(0, members)
      viewed = range.members_who_viewed.to_i.clamp(spoke, members)
      read_only = viewed - spoke
      never = members - viewed

      [["spoke", "spoke", spoke], ["read", "read only", read_only],
       ["never", "never opened", never]].map do |key, label, folk|
        Part.new(key: key, label: label, people: folk,
          share: (folk * 100.0 / members).round(1))
      end
    end

    def curve
      @curve ||= Analytics::MartChannelConcentration
        .where(channel_id: channel_id, month: month).order(:poster_pct).to_a
    end

    def concentration
      curve.first
    end

    def gini
      concentration&.gini&.to_f
    end

    def half_mark
      curve.find { |point| point.message_pct.to_f >= 50 }
    end
  end
end
