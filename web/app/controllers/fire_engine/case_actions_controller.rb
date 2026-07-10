module FireEngine
  class CaseActionsController < BaseController
    def create
      target_user_ids = params[:target_user_ids].to_s.split(",").map(&:strip).reject(&:blank?)

      LylaClient.new.create_case_action(
        case_number: params[:case_id].to_i,
        target_user_ids: target_user_ids,
        violation: params[:violation],
        solution: params[:action_type],
        category_extra: params[:category].presence,
        ban_until: params[:ban_until].presence,
        performed_by: [current_staff.user_id]
      )

      redirect_to fire_engine_case_path(params[:case_id]), notice: "conduct report filed"
    rescue LylaClient::Error => e
      redirect_to fire_engine_case_path(params[:case_id]), alert: "could not file conduct report: #{e.message}"
    end
  end
end
