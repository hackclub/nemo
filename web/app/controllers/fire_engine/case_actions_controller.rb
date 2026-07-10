module FireEngine
  class CaseActionsController < BaseController
    def create
      redirect_to fire_engine_case_path(params[:case_id]),
        notice: "conduct report filed (mock — not yet wired to lyla)"
    end
  end
end
