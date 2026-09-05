module Engine
  module Columns
    SCHEMA = "analytics".freeze

    def self.has?(relation, column)
      names(relation).include?(column.to_s)
    end

    def self.names(relation)
      known[relation.to_s]
    end

    def self.reset!
      @known = nil
    end

    def self.known
      @known ||= Hash.new do |cache, relation|
        cache[relation] = begin
          ActiveRecord::Base.connection.columns("#{SCHEMA}.#{relation}").map(&:name)
        rescue ActiveRecord::StatementInvalid
          []
        end
      end
    end
  end
end
