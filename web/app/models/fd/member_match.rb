module Fd
  module MemberMatch
    UNIQUE = %i[handle user_id].freeze
    NAMED = %i[display_name handle user_id].freeze
    SHOWN = %i[shown_name real_name email].freeze

    module_function

    def tiers(identity)
      held = [[UNIQUE, :exact], [NAMED, :exact], [NAMED, :starts], [NAMED, :within]]
      return held unless identity

      held.insert(2, [SHOWN, :exact])
      held.insert(4, [SHOWN, :starts])
      held << [SHOWN, :within]
      held
    end

    def rank(identity:, columns:)
      held = tiers(identity)
      whens = held.each_with_index.filter_map do |(fields, how), place|
        test = fields.filter_map { |field| test_for(columns[field], how) }
        "WHEN #{test.join(' OR ')} THEN #{place}" if test.any?
      end
      return "0" if whens.empty?

      "CASE #{whens.join(' ')} ELSE #{held.size} END"
    end

    def ranked(term, identity:, columns:)
      ApplicationRecord.sanitize_sql_array(
        [rank(identity: identity, columns: columns), binds(term)]
      )
    end

    def test_for(column, how)
      return nil if column.blank?

      case how
      when :exact then "lower(coalesce(#{column}, '')) = :exact"
      when :starts then "lower(#{column}) LIKE :starts"
      else "lower(#{column}) LIKE :within"
      end
    end

    def binds(term)
      said = term.to_s.downcase
      like = ApplicationRecord.sanitize_sql_like(said)
      { exact: said, starts: "#{like}%", within: "%#{like}%" }
    end
  end
end
