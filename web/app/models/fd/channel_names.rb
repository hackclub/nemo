module Fd
  class ChannelNames
    PRIVATE_VISIBILITY = "private".freeze

    def self.for(channel_ids)
      wanted = Array(channel_ids).flatten.compact.uniq
      return none if wanted.empty?

      rows = Analytics::DimChannel.where(channel_id: wanted)
        .pluck(:channel_id, :name, :visibility)
      names = rows.to_h { |channel_id, name, _| [channel_id, name] }.compact_blank
      private_unnamed = rows.filter_map { |channel_id, name, visibility|
        channel_id if name.blank? && visibility == PRIVATE_VISIBILITY
      }.to_set

      new(names, private_unnamed)
    end

    def self.none = new

    def initialize(names = {}, private_unnamed = Set.new)
      @names = names
      @private_unnamed = private_unnamed
    end

    def [](channel_id)
      return "no channel" if channel_id.blank?

      name = @names[channel_id]
      name.present? ? "##{name}" : channel_id
    end

    def named?(channel_id)
      @names[channel_id].present?
    end

    def private_unnamed?(channel_id)
      @private_unnamed.include?(channel_id)
    end
  end
end
