module Fd
  class IpCohort < ApplicationRecord
    self.table_name = "fd.ip_cohort"
    self.primary_key = "ip_prefix"

    def readonly?
      persisted?
    end
  end
end
