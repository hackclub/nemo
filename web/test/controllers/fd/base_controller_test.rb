require "test_helper"

class Fd::BaseControllerTest < ActiveSupport::TestCase
  def controller(verb)
    Fd::BaseController.new.tap do |c|
      c.instance_variable_set(:@_request, ActionDispatch::TestRequest.create("REQUEST_METHOD" => verb))
    end
  end

  def before_callbacks(controller)
    controller._process_action_callbacks.select { |c| c.kind == :before }.map(&:filter)
  end

  test "reads are not gated, every other verb is" do
    assert controller("GET").send(:read_only_request?)
    assert controller("HEAD").send(:read_only_request?)
    %w[POST PATCH PUT DELETE].each do |verb|
      assert_not controller(verb).send(:read_only_request?), "#{verb} must be gated"
    end
  end

  test "a controller that writes without declaring a permission refuses to run" do
    names = Fd::BaseController._process_action_callbacks.map(&:filter)
    assert_includes names, :require_a_declaration
    assert_includes names, :require_account

    bare = Class.new(Fd::BaseController)
    assert_empty bare.declared
    assert_raises(RuntimeError) { bare.new.send(:require_a_declaration) }
  end

  test "the gate runs after sign in, so it never leaks to a stranger" do
    names = Fd::BaseController._process_action_callbacks.map(&:filter)
    assert names.index(:require_account) < names.index(:require_a_declaration)
  end

  test "forgery protection runs before the gate" do
    names = before_callbacks(Fd::CasesController)
    assert names.index(:verify_authenticity_token) < names.index(:require_a_declaration)
  end

  test "every conduct controller that writes declares what it needs" do
    Rails.application.eager_load!
    writing = Fd::BaseController.descendants.reject do |controller|
      (controller.action_methods & %w[create update destroy]).empty?
    end

    assert writing.size >= 15, "expected the whole conduct area, saw #{writing.size}"
    writing.each do |controller|
      assert controller.declared.any?, "#{controller} writes without a permission"
      controller.declared.each do |key|
        assert_includes Authz.keys, key, "#{controller} names #{key}, which does not exist"
      end
    end
  end
end
