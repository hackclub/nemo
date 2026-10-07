require "test_helper"

class Profile::SummaryTest < ActiveSupport::TestCase
  include SeedsPipelineTables

  IDLE = "UIDLEONE".freeze

  def loaded!(source, on)
    as_pipeline("INSERT INTO raw.analytics_day (source, ds, loaded) VALUES (?, ?, true) " \
                "ON CONFLICT (source, ds) DO UPDATE SET loaded = true", source, on)
    seeded!("raw.analytics_day", "ds", on)
  end

  def joined(on)
    Profile::Summary.new(IDLE).tap do |person|
      person.define_singleton_method(:member_since) { on }
    end
  end

  test "an idle stretch on days we loaded reads zero, not untracked" do
    loaded!("member_day", Date.new(2020, 1, 15))

    counted = Profile::Summary.new(IDLE).slack(Date.new(2020, 1, 10), Date.new(2020, 1, 20))

    assert_equal 0, counted[:days_active]
    assert_equal 0, counted[:messages]
  end

  test "an idle stretch in the imported years reads zero too" do
    loaded!("member_day_import", Date.new(2020, 3, 4))

    counted = Profile::Summary.new(IDLE).slack(Date.new(2020, 3, 1), Date.new(2020, 3, 7))

    assert_equal 0, counted[:days_active]
  end

  test "a stretch with no day loaded stays untracked" do
    loaded!("member_day", Date.new(2020, 1, 15))

    assert_nil Profile::Summary.new(IDLE).slack(Date.new(2019, 6, 1), Date.new(2019, 6, 30))[:days_active]
  end

  test "days before somebody joined are not counted as idle" do
    loaded!("member_day", Date.new(2020, 1, 15))

    counted = joined(Time.utc(2020, 2, 1)).slack(Date.new(2020, 1, 10), Date.new(2020, 1, 20))

    assert_nil counted[:days_active]
  end

  test "all time starts the first day Slack reported somebody, not their first active day" do
    loaded!("member_day", Date.new(2020, 1, 15))
    loaded!("member_day", Date.new(2020, 2, 3))

    assert_equal Date.new(2020, 2, 3), joined(Time.utc(2020, 2, 1)).floor
  end
end
