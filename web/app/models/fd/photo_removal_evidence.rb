module Fd
  class PhotoRemovalEvidence < ApplicationRecord
    self.table_name = "fd.photo_removal_evidence"
    self.primary_key = :removal_id

    INLINE_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze

    belongs_to :removal, class_name: "Fd::PhotoRemoval", foreign_key: :removal_id,
      inverse_of: :evidence

    def inline? = INLINE_TYPES.include?(content_type)
  end
end
