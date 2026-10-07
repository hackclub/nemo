module WarehouseBuild
  SOURCE = "dbt".freeze
  CHECKED_FOR = 1.minute
  KEPT_FOR = 2.days

  module_function

  def finished_at
    Rails.cache.fetch("warehouse_build/finished_at", expires_in: CHECKED_FOR) do
      Analytics::FctIngestRun.where(source_key: SOURCE).where.not(finished_at: nil).maximum(:finished_at)&.to_i
    end
  end

  def cached(key, &block)
    Rails.cache.fetch(["warehouse_build", finished_at, key], expires_in: KEPT_FOR, &block)
  end
end
