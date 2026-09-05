require "test_helper"

class SyncRequestTest < ActiveSupport::TestCase
  def claimed(status:)
    SyncRequest.create!(kind: "full", requested_by: "UTEST1", status: status, claimed_at: Time.current)
  end

  test "cancelling a claimed request moves it to cancelling and notifies" do
    request = claimed(status: "claimed")

    assert request.cancel!
    assert_equal "cancelling", request.status
  end

  test "cancelling an already-cancelling request stays true instead of nothing to cancel" do
    request = claimed(status: "cancelling")

    assert request.cancel!, "a second cancel click must not report nothing to cancel"
    assert_equal "cancelling", request.status
  end

  test "releasing an already-cancelling request with no worker marks it cancelled" do
    request = claimed(status: "cancelling")

    assert request.cancel!(worker_gone: true)
    assert_equal "cancelled", request.status
    assert request.finished_at.present?
  end

  test "releasing a claimed request with no worker marks it cancelled" do
    request = claimed(status: "claimed")

    assert request.cancel!(worker_gone: true)
    assert_equal "cancelled", request.status
  end

  test "a queued request is cancelled outright" do
    request = claimed(status: "queued")

    assert request.cancel!
    assert_equal "cancelled", request.status
  end

  test "a done request cannot be cancelled" do
    request = claimed(status: "done")

    assert_not request.cancel!
  end
end
