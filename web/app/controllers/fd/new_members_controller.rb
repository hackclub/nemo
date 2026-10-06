module Fd
  class NewMembersController < BaseController
    permit "case.read"

    def show
      user_id = params[:id].to_s.upcase
      row = NewMemberQuery.new({ "when" => "any" }, actor: current_account).one(user_id)
      return head :not_found if row.nil?

      render partial: "fd/new_members/card", layout: false,
        locals: { row: row, names: Names.for([user_id]) }
    end

    def index
      @query = NewMemberQuery.new(params, actor: current_account)
      @rows = @query.rows
      @views = @query.views
      @names = Names.for(@rows.map(&:user_id))
    end
  end
end
