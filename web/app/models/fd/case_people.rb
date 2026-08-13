module Fd
  class CasePeople
    include Enumerable

    RANK = { "reporter" => 0, "subject" => 1, "involved" => 2 }.freeze

    class Person
      attr_reader :user_id, :roles, :records

      def initialize(user_id, records)
        @user_id = user_id
        @records = records.sort_by { |record| RANK.fetch(record.role, 9) }
        @roles = @records.map(&:role)
      end

      def role
        roles.first
      end

      def detail
        records.map(&:detail).compact_blank.first
      end

      def subject?
        roles.include?("subject")
      end

      def reporter?
        roles.include?("reporter")
      end

      def noted_at
        records.map(&:noted_at).min
      end
    end

    def self.for(participants, asked: nil)
      new(participants, asked)
    end

    attr_reader :chosen

    def initialize(participants, asked = nil)
      @people = group(participants)
      @chosen = @people.find { |person| person.user_id == asked } || @people.first
    end

    def each(&block)
      @people.each(&block)
    end

    def size
      @people.size
    end

    def chosen?(person)
      person.user_id == @chosen&.user_id
    end

    def subjects
      @people.select(&:subject?)
    end

    private

    def group(participants)
      participants
        .group_by(&:user_id)
        .map { |user_id, records| Person.new(user_id, records) }
        .sort_by { |person| [RANK.fetch(person.role, 9), person.noted_at, person.user_id] }
    end
  end
end
