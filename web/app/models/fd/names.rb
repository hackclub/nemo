module Fd
  class Names
    FRESH_FOR = 12.hours

    def self.for(user_ids)
      wanted = Array(user_ids).flatten.compact.uniq
      return none if wanted.empty?

      known = remembered(wanted)
      stale = wanted - known.keys

      new(members: Member.where(user_id: wanted).index_by(&:user_id),
        profiles: known.merge(stale.any? ? CachetClient.profiles(stale) : {}))
    end

    def self.remembered(user_ids)
      CachetProfile.where(user_id: user_ids, fetched_at: FRESH_FOR.ago..).to_h { |row|
        [row.user_id, CachetClient::Profile.new(display_name: row.display_name,
          image_url: row.image_url, pronouns: row.pronouns)]
      }
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

    def late(_user_id)
      nil
    end
  end
end
