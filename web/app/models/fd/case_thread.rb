module Fd
  class CaseThread < ApplicationRecord
    self.table_name = "fd.case_threads"

    belongs_to :kase, class_name: "Fd::Case", foreign_key: :case_id, inverse_of: :threads

    KINDS = %w[evidence internal].freeze

    scope :primary_first, -> { order(is_primary: :desc, added_at: :asc, id: :asc) }
    scope :evidence, -> { where(kind: "evidence") }
    scope :internal, -> { where(kind: "internal") }
    scope :visible, -> { where(removed_at: nil) }

    def self.kind_for(channel_id)
      AppSetting.fd_channel_ids.include?(channel_id) ? "internal" : "evidence"
    end

    def coordinates
      [channel_id, thread_ts]
    end

    def evidence?
      kind == "evidence"
    end

    def internal?
      kind == "internal"
    end

    def removed?
      removed_at.present?
    end

    def audit_values
      { "case_id" => case_id, "channel_id" => channel_id, "thread_ts" => thread_ts, "kind" => kind }
    end
  end
end
