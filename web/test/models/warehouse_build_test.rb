require "test_helper"

class WarehouseBuildTest < ActiveSupport::TestCase
  include SeedsPipelineTables

  def newcomer_reads
    reads = 0
    listener = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, load|
      reads += 1 if load[:name] != "SCHEMA" && load[:sql].include?("mart_newcomer_channels")
    end
    yield
    reads
  ensure
    ActiveSupport::Notifications.unsubscribe(listener)
  end

  def finish_a_build!
    id = as_pipeline("INSERT INTO raw.ingest_run (source, source_key, status, started_at, finished_at) " \
                     "VALUES ('dbt', 'dbt', 'ok', '2100-01-01', '2100-01-01 00:30') RETURNING id").first["id"]
    seeded!("raw.ingest_run", "id", id)
    ApplicationRecord.connection.clear_query_cache
  end

  test "a mart read is kept until the next dbt build finishes" do
    with_a_real_cache do
      assert_equal 1, newcomer_reads { Analytics::MartNewcomerChannels.cohorts }
      assert_equal 0, newcomer_reads { Analytics::MartNewcomerChannels.cohorts }

      finish_a_build!
      travel WarehouseBuild::CHECKED_FOR + 1.second do
        assert_equal 1, newcomer_reads { Analytics::MartNewcomerChannels.cohorts }
      end
    end
  end
end
