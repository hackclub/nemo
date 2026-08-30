module Fd
  class Names
    LATE_LOOKUPS = 8

    def self.for(user_ids)
      wanted = Array(user_ids).flatten.compact.uniq
      return none if wanted.empty?

      new(members: Member.where(user_id: wanted).index_by(&:user_id),
        profiles: CachetClient.profiles(wanted))
    end

    def self.none = new

    def initialize(members: {}, profiles: {})
      @members = members
      @profiles = profiles
      @shown = {}
      @late = 0
    end

    def [](user_id)
      return "n/a" if user_id.blank?

      @shown[user_id] ||= said_for(user_id) || "@#{user_id}"
    end

    def image(user_id)
      return nil if user_id.blank?

      profile(user_id)&.image_url.presence
    end

    def initial(user_id)
      shown = self[user_id].sub(/\A@/, "").strip
      shown.present? ? shown[0].upcase : "?"
    end

    def member(user_id)
      @members[user_id]
    end

    def known?(user_id)
      @members.key?(user_id) || @profiles.key?(user_id)
    end

    def list(user_ids)
      Array(user_ids).map { |id| self[id] }.to_sentence
    end

    private

    def said_for(user_id)
      profile(user_id)&.display_name.presence || @members[user_id]&.name
    end

    def profile(user_id)
      return @profiles[user_id] if @profiles.key?(user_id)

      @profiles[user_id] = late(user_id)
    end

    def late(user_id)
      return nil if @late >= LATE_LOOKUPS

      @late += 1
      CachetClient.profiles([user_id])[user_id]
    end
  end
end
