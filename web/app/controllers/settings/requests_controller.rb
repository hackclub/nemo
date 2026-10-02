module Settings
  class RequestsController < BaseController
    before_action :require_reviewer, only: [:index, :settle]

    SHOWN = 50

    RANK = { Api::AccessRequest::PENDING => 0, Api::AccessRequest::APPROVED => 1,
             Api::AccessRequest::DECLINED => 2, Api::AccessRequest::WITHDRAWN => 3 }.freeze

    def index
      waiting = Api::AccessRequest.queue.includes(:app).to_a
      settled = Api::AccessRequest.settled.includes(:app)
        .order(decided_at: :desc).limit(SHOWN).to_a

      @rows = waiting + settled.sort_by { |row| [RANK.fetch(row.state, 9), -row.decided_at.to_i] }
      @waiting = waiting.size
      @names = Fd::Names.for(named_in(@rows))
    end

    def create
      app = Api::App.live.find_by(id: params[:app_id], owner_user_id: member_id)
      return back("that app is not yours") if app.nil?

      Api::AccessRequest.ask!(app, reason: params[:reason])
      redirect_to settings_keys_path, notice: "Asked for access for #{app.name}"
    rescue Api::AccessRequest::TooThin
      back "say what the app needs access for"
    rescue Api::AccessRequest::Already
      back "that app has already asked"
    end

    def withdraw
      asked = Api::AccessRequest.pending.includes(:app).find_by(id: params[:id])
      return back("that request is not yours") if asked&.app&.owner_user_id != member_id

      asked.withdraw!
      redirect_to settings_keys_path, notice: "Withdrawn"
    end

    def settle
      asked = Api::AccessRequest.pending.includes(:app).find_by(id: params[:id])
      return redirect_to(settings_requests_path, alert: "already settled") if asked.nil?

      yes = params[:verdict].to_s.casecmp?("approve")
      asked.public_send(yes ? :approve! : :decline!, by: member_id, note: params[:note])
      said = yes ? "Approved" : "Declined"
      redirect_to settings_requests_path, notice: "#{said} #{asked.app.name}"
    end

    private

    def named_in(rows)
      rows.flat_map { |row| [row.app.owner_user_id, row.decided_by] }.compact.uniq
    end

    def back(said)
      redirect_to settings_keys_path, alert: said
    end

    def require_reviewer
      return if Authz.holds?(current_account, "api.review")

      redirect_to settings_keys_path, alert: "reviewing api access is not yours to do"
    end
  end
end
