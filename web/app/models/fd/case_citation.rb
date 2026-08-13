module Fd
  class CaseCitation < ApplicationRecord
    self.table_name = "fd.case_citations"

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, inverse_of: :citations
    belongs_to :message, class_name: "Fd::ThreadMessage", foreign_key: :thread_message_id

    scope :oldest_first, -> { order(:flagged_at) }
  end
end
