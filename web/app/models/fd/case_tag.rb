module Fd
  class CaseTag < ApplicationRecord
    self.table_name = "fd.case_tags"
    self.primary_key = [:case_id, :tag_id]

    MAX_PER_CASE = 10

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, inverse_of: :case_tags
    belongs_to :tag, class_name: "Fd::Tag", foreign_key: :tag_id, inverse_of: :case_tags

    validates :tag_id, uniqueness: { scope: :case_id, message: "Tag already on case" }
    validate :within_tag_limit, on: :create

    scope :oldest_first, -> { order(:added_at, :tag_id) }

    def self.release_merge!(case_id, merge_id)
      copied = where(case_id: case_id, merge_id: merge_id).includes(:tag).to_a
      copied.filter_map do |row|
        keeper = CaseMerge.live.where(into_case_id: case_id).where.not(id: merge_id)
          .where(case_id: where(tag_id: row.tag_id).select(:case_id)).order(:id).pick(:id)
        rows = where(case_id: case_id, tag_id: row.tag_id)
        if keeper
          rows.update_all(merge_id: keeper)
          next
        end

        rows.delete_all
        row.tag
      end
    end

    private

    def within_tag_limit
      return if self.class.where(case_id: case_id).count < MAX_PER_CASE

      errors.add(:base, "Limit of #{MAX_PER_CASE} tags per case")
    end
  end
end
