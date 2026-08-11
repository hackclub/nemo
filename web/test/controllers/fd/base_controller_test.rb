require "test_helper"

class Fd::BaseControllerTest < ActiveSupport::TestCase
  def controller(verb)
    Fd::BaseController.new.tap do |c|
      c.instance_variable_set(:@_request, ActionDispatch::TestRequest.create("REQUEST_METHOD" => verb))
    end
  end

  test "reads are not gated, every other verb is" do
    assert controller("GET").send(:read_only_request?)
    assert controller("HEAD").send(:read_only_request?)
    %w[POST PATCH PUT DELETE].each do |verb|
      assert_not controller(verb).send(:read_only_request?), "#{verb} must be gated"
    end
  end

  test "the write gate is registered for the whole conduct area" do
    names = Fd::BaseController._process_action_callbacks.map(&:filter)
    assert_includes names, :require_write
    assert_includes names, :require_staff
  end

  test "the write gate runs after sign in, so it never leaks to a stranger" do
    names = Fd::BaseController._process_action_callbacks.map(&:filter)
    assert names.index(:require_staff) < names.index(:require_write)
  end

  ALLOWED_BEFORE_GATE = %i[verify_authenticity_token require_staff].freeze

  def before_callbacks(controller)
    controller._process_action_callbacks.select { |c| c.kind == :before }.map(&:filter)
  end

  test "forgery protection runs before the write gate" do
    names = before_callbacks(Fd::CasesController)
    assert names.index(:verify_authenticity_token) < names.index(:require_write)
  end

  test "nothing the app declares runs before the write gate" do
    names = before_callbacks(Fd::CasesController)
    earlier = names.take(names.index(:require_write)).grep(Symbol)
    assert_equal [], earlier - ALLOWED_BEFORE_GATE,
      "a callback runs before the write gate and could leak whether a record exists"
  end

  test "nobody without the staff flag may write" do
    c = Fd::BaseController.new
    def c.current_staff = nil
    assert_equal false, c.send(:may_write?)

    denied = Staff.new(user_id: "U1", community_manager: false)
    def c.current_staff = @staff
    c.instance_variable_set(:@staff, denied)
    assert_equal false, c.send(:may_write?)

    c.instance_variable_set(:@staff, Staff.new(user_id: "U2", community_manager: true))
    assert_equal true, c.send(:may_write?)
  end
end
