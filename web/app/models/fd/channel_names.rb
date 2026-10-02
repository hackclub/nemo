module Fd
  class ChannelNames
    def self.for(channel_ids)
      wanted = Array(channel_ids).flatten.compact.uniq
      return none if wanted.empty?

      new(Analytics::DimChannel.where(channel_id: wanted).pluck(:channel_id, :name)
        .to_h.compact_blank)
    end

    def self.none = new

    def initialize(names = {})
      @names = names
    end

    def [](channel_id)
      return "no channel" if channel_id.blank?

      name = @names[channel_id]
      name.present? ? "##{name}" : "unnamed channel"
    end

    def named?(channel_id)
      @names[channel_id].present?
    end
  end
end
