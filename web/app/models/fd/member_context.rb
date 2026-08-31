module Fd
  class MemberContext
    def self.for(user_ids)
      ids = user_ids.compact.uniq
      return {} if ids.empty?

      members = Analytics::DimMember.where(user_id: ids).index_by(&:user_id)
      windows = Analytics::MemberWindow.lifetime.where(user_id: ids).index_by(&:user_id)
      ids.to_h { |id| [id, new(id, members[id], windows[id])] }
    end

    attr_reader :user_id

    def initialize(user_id, member, window)
      @user_id = user_id
      @member = member
      @window = window
    end

    def known?
      @member.present?
    end

    def tenure_days
      return nil if @member&.cohort_at.nil?

      (Date.current - @member.cohort_at.to_date).to_i
    end

    def cohort_at
      @member&.cohort_at
    end

    def claimed_at
      @member&.claimed_at
    end

    def days_active
      @window&.days_active
    end

    def messages_posted
      @window&.messages_posted
    end

    def last_active_at
      @window&.last_active_at
    end
  end
end
