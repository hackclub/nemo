module FireEngine
  class NotesController < BaseController
    def create
      LylaClient.new.create_note(params[:member_id], body: params[:body], created_by: current_staff.user_id)
      redirect_to fire_engine_member_path(params[:member_id]), notice: "note added"
    rescue LylaClient::Error => e
      redirect_to fire_engine_member_path(params[:member_id]), alert: "could not add note: #{e.message}"
    end
  end
end
