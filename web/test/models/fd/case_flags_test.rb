require "test_helper"

class Fd::CaseFlagsTest < ActiveSupport::TestCase
  test "an unclaimed case past the threshold is flagged" do
    kase = make_case(opened_at: 6.days.ago)
    flags = Fd::CaseFlags.for_case(kase)

    assert_equal 1, flags.size
    assert_equal "crit", flags.first.tone
    assert_match(/has sat unclaimed for 6 days/, flags.first.headline)
  end

  test "a claimed case is not flagged as unclaimed" do
    kase = make_case(opened_at: 6.days.ago, assign: "UFF1")
    assert_empty Fd::CaseFlags.for_case(kase)
  end

  test "a fresh unclaimed case is not flagged yet" do
    kase = make_case(opened_at: 1.day.ago)
    assert_empty Fd::CaseFlags.for_case(kase)
  end

  test "a resolved case is never flagged as unclaimed" do
    kase = make_case(opened_at: 10.days.ago, resolved_at: Time.current, resolution: "no_action")
    assert_empty Fd::CaseFlags.for_case(kase)
  end

  test "a third report on the same subject within 30 days is flagged" do
    make_case(subject: "UPRIOR", opened_at: 20.days.ago, assign: "UFF1")
    make_case(subject: "UPRIOR", opened_at: 10.days.ago, assign: "UFF1")
    kase = make_case(subject: "UPRIOR", opened_at: 1.day.ago)

    flags = Fd::CaseFlags.for_case(kase, names: Fd::Names.none)

    priors = flags.find { |f| f.headline.include?("report about") }
    assert_not_nil priors
    assert_equal "crit", priors.tone
    assert_match(/3rd report about @UPRIOR in 30 days/, priors.headline)
  end

  test "only two reports in 30 days does not trigger the priors flag" do
    make_case(subject: "UPRIOR", opened_at: 10.days.ago, assign: "UFF1")
    kase = make_case(subject: "UPRIOR", opened_at: 1.day.ago)

    assert_empty Fd::CaseFlags.for_case(kase)
  end

  test "reports outside the 30 day window do not count" do
    make_case(subject: "UPRIOR", opened_at: 40.days.ago, assign: "UFF1")
    make_case(subject: "UPRIOR", opened_at: 35.days.ago, assign: "UFF1")
    kase = make_case(subject: "UPRIOR", opened_at: 1.day.ago)

    assert_empty Fd::CaseFlags.for_case(kase)
  end

  test "a case about several subjects is not flagged for priors" do
    kase = make_case(subject: "UAAA", opened_at: 1.day.ago)
    kase.add_subject!("UBBB")

    assert_empty Fd::CaseFlags.for_case(kase)
  end

  test "two open cases sharing a Slack thread are flagged as worth merging" do
    a = make_case(opened_at: 2.days.ago)
    b = make_case(opened_at: 1.day.ago)
    Fd::CaseThread.create!(case_id: a.id, channel_id: "C1", thread_ts: "1.1",
      kind: "evidence", is_primary: true, added_by: "UFF1", added_at: Time.current)
    Fd::CaseThread.create!(case_id: b.id, channel_id: "C1", thread_ts: "1.1",
      kind: "evidence", is_primary: true, added_by: "UFF1", added_at: Time.current)

    flags = Fd::CaseFlags.for_case(b)
    merge = flags.find { |f| f.detail == "Worth merging." }

    assert_not_nil merge
    assert_equal "mid", merge.tone
    assert_match(/Case #{a.id} is about the same thread/, merge.headline)
  end

  test "a resolved sibling case does not trigger a merge hint" do
    a = make_case(opened_at: 2.days.ago, resolved_at: Time.current, resolution: "no_action")
    b = make_case(opened_at: 1.day.ago)
    Fd::CaseThread.create!(case_id: a.id, channel_id: "C1", thread_ts: "1.1",
      kind: "evidence", is_primary: true, added_by: "UFF1", added_at: Time.current)
    Fd::CaseThread.create!(case_id: b.id, channel_id: "C1", thread_ts: "1.1",
      kind: "evidence", is_primary: true, added_by: "UFF1", added_at: Time.current)

    assert_empty Fd::CaseFlags.for_case(b)
  end

  test "the queue surfaces the oldest unclaimed case, not every unclaimed case" do
    make_case(opened_at: 6.days.ago)
    make_case(opened_at: 8.days.ago)

    flags = Fd::CaseFlags.for_queue
    unclaimed = flags.select { |f| f.headline.include?("unclaimed") }

    assert_equal 1, unclaimed.size
  end
end
