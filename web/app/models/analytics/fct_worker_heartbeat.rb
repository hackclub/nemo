module Analytics
  class FctWorkerHeartbeat < ApplicationRecord
    self.table_name = "analytics.fct_worker_heartbeat"
    self.primary_key = "worker"

    SYNC_WORKER = "sync_worker".freeze
    COLD_AFTER = 5.minutes

    def readonly?
      true
    end

    def self.sync_worker
      find_by(worker: SYNC_WORKER)
    end

    def cold?
      Time.current - beat_at > COLD_AFTER
    end
  end
end
