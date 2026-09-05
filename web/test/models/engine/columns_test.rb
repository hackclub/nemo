require "test_helper"

module Engine
  class ColumnsTest < ActiveSupport::TestCase
    setup { Engine::Columns.reset! }
    teardown { Engine::Columns.reset! }

    test "a column the view has is reported present" do
      assert Engine::Columns.has?(:fct_ingest_run, :status)
      assert Engine::Columns.has?("fct_ingest_run", "rows_in")
    end

    test "a column the view does not have yet is reported absent without raising" do
      assert_not Engine::Columns.has?(:fct_ingest_run, :coverage_ratio)
    end

    test "a relation that does not exist is reported empty without raising" do
      assert_equal [], Engine::Columns.names(:no_such_view)
      assert_not Engine::Columns.has?(:no_such_view, :anything)
    end

    test "the lookup is memoised per relation" do
      first = Engine::Columns.names(:fct_ingest_run)
      assert_same first, Engine::Columns.names(:fct_ingest_run)
    end
  end
end
