require "test_helper"

module Fd
  class ActionTest < ActiveSupport::TestCase
    def action(**attrs)
      Fd::Action.new({ type_key: "warning", target_user_id: "USEED0000001",
                       decided_by: "UFF1", performed_by: "UFF1" }.merge(attrs))
    end

    test "a plain action is active" do
      subject = action
      assert_not subject.reversed?
      assert_not subject.expires?
      assert_not subject.expired?
      assert subject.active?
    end

    test "an action with a future expiry is not yet expired" do
      subject = action(expires_at: 5.days.from_now)
      assert subject.expires?
      assert_not subject.expired?
      assert subject.active?
    end

    test "an action past its expiry is expired and no longer active" do
      subject = action(expires_at: 1.hour.ago)
      assert subject.expired?
      assert_not subject.active?
    end

    test "expiry is evaluated at the time you ask about" do
      subject = action(expires_at: 5.days.from_now)
      assert_not subject.expired?(Time.current)
      assert subject.expired?(6.days.from_now)
    end

    test "a reversed action is not expired, it is reversed" do
      subject = action(expires_at: 1.hour.ago, reversed_at: 2.hours.ago, reversed_by: "UFF2")
      assert subject.reversed?
      assert_not subject.expired?
      assert_not subject.active?
    end

    test "a reversed action with no expiry is inactive" do
      subject = action(reversed_at: Time.current, reversed_by: "UFF2")
      assert_not subject.active?
    end

    test "performed_by_decider is true only when the same person did both" do
      assert action(decided_by: "UFF1", performed_by: "UFF1").performed_by_decider?
      assert_not action(decided_by: "UFF1", performed_by: "UMNEMOSYNE").performed_by_decider?
    end

    test "live and reversed scopes partition the table" do
      kase = Fd::Case.create!(opened_by: "UFF1", external_ref: "test:action:scopes")
      kept = Fd::Action.create!(case_id: kase.id, type_key: "warning",
        target_user_id: "USEED0000001", decided_by: "UFF1", performed_by: "UFF1")
      undone = Fd::Action.create!(case_id: kase.id, type_key: "shush",
        target_user_id: "USEED0000001", decided_by: "UFF1", performed_by: "UFF1",
        reversed_at: Time.current, reversed_by: "UFF2")

      assert_includes kase.actions.live, kept
      assert_not_includes kase.actions.live, undone
      assert_includes kase.actions.reversed, undone
      assert_equal kase.actions.count, kase.actions.live.count + kase.actions.reversed.count
    end

    test "expiring covers live actions with an expiry and excludes reversed ones" do
      kase = Fd::Case.create!(opened_by: "UFF1", external_ref: "test:action:expiring")
      live_expiring = Fd::Action.create!(case_id: kase.id, type_key: "shush",
        target_user_id: "USEED0000001", decided_by: "UFF1", performed_by: "UFF1",
        expires_at: 3.days.from_now)
      Fd::Action.create!(case_id: kase.id, type_key: "temp_ban",
        target_user_id: "USEED0000001", decided_by: "UFF1", performed_by: "UFF1",
        expires_at: 3.days.from_now, reversed_at: Time.current, reversed_by: "UFF2")
      Fd::Action.create!(case_id: kase.id, type_key: "warning",
        target_user_id: "USEED0000001", decided_by: "UFF1", performed_by: "UFF1")

      assert_equal [live_expiring], kase.actions.expiring.to_a
    end

    test "for_target finds actions aimed at someone who is not the subject" do
      kase = Fd::Case.create!(opened_by: "UFF1", subject_user_id: "USEED0000001",
        external_ref: "test:action:target")
      to_subject = Fd::Action.create!(case_id: kase.id, type_key: "warning",
        target_user_id: "USEED0000001", decided_by: "UFF1", performed_by: "UFF1")
      to_other = Fd::Action.create!(case_id: kase.id, type_key: "dm",
        target_user_id: "USEED0000009", decided_by: "UFF1", performed_by: "UFF1")

      assert_equal [to_subject], Fd::Action.for_target("USEED0000001").where(case_id: kase.id).to_a
      assert_equal [to_other], Fd::Action.for_target("USEED0000009").where(case_id: kase.id).to_a
    end
  end
end
