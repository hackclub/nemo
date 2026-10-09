module Fd
  class LinkVerdict < ApplicationRecord
    self.table_name = "fd.member_link_verdict"

    VERDICTS = {
      "same_person" => "Same person",
      "different_people" => "Different people",
      "household" => "Household",
      "staff_test" => "Staff test"
    }.freeze
    ONE_PERSON = %w[same_person staff_test].freeze

    def self.pair(one, other) = [one.to_s, other.to_s].minmax

    def self.for_pairs(pairs)
      wanted = pairs.map { |one, other| pair(one, other) }.uniq
      return {} if wanted.empty?

      where(a_user_id: wanted.map(&:first), b_user_id: wanted.map(&:last))
        .index_by { |row| [row.a_user_id, row.b_user_id] }.slice(*wanted)
    end

    def self.of(verdicts, one, other) = verdicts[pair(one, other)]

    def label = VERDICTS.fetch(verdict, verdict)

    def one_person? = ONE_PERSON.include?(verdict)

    def verb = one_person? ? "linked" : "unlinked"

    def said = { "verdict" => verdict, "decided_by" => decided_by, "note" => note }
  end
end
