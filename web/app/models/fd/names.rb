module Fd
  class Names
    def self.for(user_ids)
      new(CachetClient.profiles(Array(user_ids).flatten.compact.uniq))
    end

    def self.none = new({})

    def initialize(profiles)
      @profiles = profiles
    end

    def [](user_id)
      return "n/a" if user_id.blank?

      @profiles[user_id]&.display_name.presence || "@#{user_id}"
    end

    def known?(user_id)
      @profiles.key?(user_id)
    end

    def list(user_ids)
      Array(user_ids).map { |id| self[id] }.to_sentence
    end
  end
end
