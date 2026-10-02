module Fd
  class IntakeFileBlob < ApplicationRecord
    self.table_name = "fd.intake_file_blobs"
    self.primary_key = "sha256"

    def self.bytes_for(sha)
      return nil if sha.blank?

      where(sha256: sha).pick(:body)
    end
  end
end
