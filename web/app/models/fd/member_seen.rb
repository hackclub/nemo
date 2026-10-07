module Fd
  class MemberSeen < ApplicationRecord
    self.table_name = "fd.member_seen"
    self.primary_key = "user_id"
  end
end
