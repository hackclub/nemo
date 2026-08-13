module Fd
  class Names
    def self.for(user_ids)
      wanted = Array(user_ids).flatten.compact.uniq
      return none if wanted.empty?

      members = Member.where(user_id: wanted).index_by(&:user_id)
      new(members: members, profiles: CachetClient.profiles(wanted - members.keys))
    end

    def self.none = new

    def initialize(members: {}, profiles: {})
      @members = members
      @profiles = profiles
    end

    def [](user_id)
      return "n/a" if user_id.blank?

      member = @members[user_id]
      return member.name if member

      @profiles[user_id]&.display_name.presence || "@#{user_id}"
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
  end
end
