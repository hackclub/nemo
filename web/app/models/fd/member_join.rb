module Fd
  class MemberJoin < ApplicationRecord
    self.table_name = "fd.member_joins"
    self.primary_key = "user_id"
  end
end
