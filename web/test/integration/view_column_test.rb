require "test_helper"

class ViewColumnTest < ActionDispatch::IntegrationTest
  MODELS = Dir[Rails.root.join("app/models/analytics/*.rb")].map do |path|
    "Analytics::#{File.basename(path, '.rb').camelize}".constantize
  end.freeze

  ENGINE_READS = {
    "Analytics::FctIngestRun" => %w[id parent_run_id source step_index step_total status
                                    started_at finished_at rows_in total_expected progress_share],
    "Analytics::FctIngestStepOutput" => %w[parent_run_id step_index source output],
    "Analytics::FctAnalyticsDay" => %w[source ds loaded unavailable],
    "Analytics::FctWorkerHeartbeat" => %w[worker beat_at note]
  }.freeze

  test "every analytics relation a Rails model points at exists" do
    MODELS.each do |model|
      assert model.table_exists?, "#{model.table_name} is missing, dbt has not built it"
    end
  end

  test "every column the engine page reads exists on the view it reads it from" do
    ENGINE_READS.each do |name, columns|
      model = name.constantize
      missing = columns - model.column_names
      assert_empty missing, "#{model.table_name} lacks #{missing.join(', ')}"
    end
  end
end
