class HealthController < ActionController::Base
  def show
    ActiveRecord::Base.connection.select_value("SELECT 1")
    head :ok
  rescue StandardError
    head :service_unavailable
  end
end
