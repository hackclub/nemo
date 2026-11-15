require "test_helper"

class Fd::CaseFlagsTest < ActiveSupport::TestCase
  test "for_case flags an unclaimed case past the threshold as crit" do
    kase = make_case(opened_at: 6.days.ago)
    flags = Fd::CaseFlags.for_case(kase)

    assert_equal 1, flags.size
    assert_equal "crit", flags.first.tone
    assert_match(/unclaimed for 6 days/, flags.first.headline)
  end

  test "for_case does not flag a claimed case as unclaimed" do
    kase = make_case(opened_at: 6.days.ago, assign: "UFF1")
    assert_empty Fd::CaseFlags.for_case(kase)
  end

  test "for_case does not flag a fresh unclaimed case" do
    kase = make_case(opened_at: 1.day.ago)
    assert_empty Fd::CaseFlags.for_case(kase)
  end

  test "for_case does not flag a resolved case as unclaimed" do
    kase = make_case(opened_at: 10.days.ago, resolved_at: Time.current, resolution: "no_action")
    assert_empty Fd::CaseFlags.for_case(kase)
  end

  test "for_case flags a third report on the same subject within 30 days" do
    make_case(subject: "UPRIOR", opened_at: 20.days.ago, assign: "UFF1")
    make_case(subject: "UPRIOR", opened_at: 10.days.ago, assign: "UFF1")
    kase = make_case(subject: "UPRIOR", opened_at: 1.day.ago)

    flags = Fd::CaseFlags.for_case(kase, names: Fd::Names.none)

    priors = flags.find { |f| f.headline.include?("report about") }
    assert_not_nil priors
    assert_equal "crit", priors.tone
    assert_match(/3rd report about @UPRIOR in 30 days/, priors.headline)
  end

  test "for_case does not flag priors with two reports in 30 days" do
    make_case(subject: "UPRIOR", opened_at: 10.days.ago, assign: "UFF1")
    kase = make_case(subject: "UPRIOR", opened_at: 1.day.ago)

    assert_empty Fd::CaseFlags.for_case(kase)
  end

  test "for_case ignores reports outside the 30 day window" do
    make_case(subject: "UPRIOR", opened_at: 40.days.ago, assign: "UFF1")
    make_case(subject: "UPRIOR", opened_at: 35.days.ago, assign: "UFF1")
    kase = make_case(subject: "UPRIOR", opened_at: 1.day.ago)

    assert_empty Fd::CaseFlags.for_case(kase)
  end

  test "for_case does not flag priors on a case with several subjects" do
    kase = make_case(subject: "UAAA", opened_at: 1.day.ago)
    kase.add_subject!("UBBB")

    assert_empty Fd::CaseFlags.for_case(kase)
  end

  test "for_case flags open cases sharing a thread with a merge headline" do
    a = make_case(opened_at: 2.days.ago)
    b = make_case(opened_at: 1.day.ago)
    Fd::CaseThread.create!(case_id: a.id, channel_id: "C1", thread_ts: "1.1",
      kind: "evidence", is_primary: true, added_by: "UFF1", added_at: Time.current)
    Fd::CaseThread.create!(case_id: b.id, channel_id: "C1", thread_ts: "1.1",
      kind: "evidence", is_primary: true, added_by: "UFF1", added_at: Time.current)

    flags = Fd::CaseFlags.for_case(b)
    merge = flags.find { |f| f.headline.include?("shares a thread") }

    assert_not_nil merge
    assert_equal "mid", merge.tone
    assert_match(/Case #{a.id} shares a thread/, merge.headline)
  end

  test "for_case does not flag a merge with a resolved case sharing a thread" do
    a = make_case(opened_at: 2.days.ago, resolved_at: Time.current, resolution: "no_action")
    b = make_case(opened_at: 1.day.ago)
    Fd::CaseThread.create!(case_id: a.id, channel_id: "C1", thread_ts: "1.1",
      kind: "evidence", is_primary: true, added_by: "UFF1", added_at: Time.current)
    Fd::CaseThread.create!(case_id: b.id, channel_id: "C1", thread_ts: "1.1",
      kind: "evidence", is_primary: true, added_by: "UFF1", added_at: Time.current)

    assert_empty Fd::CaseFlags.for_case(b)
  end

  test "for_case does not flag a thread removed from one of the cases" do
    a = make_case(opened_at: 2.days.ago)
    b = make_case(opened_at: 1.day.ago)
    Fd::CaseThread.create!(case_id: a.id, channel_id: "C1", thread_ts: "1.1", kind: "evidence",
      added_by: "UFF1", added_at: Time.current, removed_at: Time.current, removed_by: "UFF1")
    Fd::CaseThread.create!(case_id: b.id, channel_id: "C1", thread_ts: "1.1",
      kind: "evidence", is_primary: true, added_by: "UFF1", added_at: Time.current)

    assert_nil Fd::CaseFlags.for_case(b).find { |flag| flag.headline.include?("share") }
  end

  test "for_queue returns one unclaimed flag for several unclaimed cases" do
    make_case(opened_at: 6.days.ago)
    make_case(opened_at: 8.days.ago)

    flags = Fd::CaseFlags.for_queue
    unclaimed = flags.select { |f| f.headline.include?("unclaimed") }

    assert_equal 1, unclaimed.size
  end
end
