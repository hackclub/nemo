require "test_helper"

class ImportmapTest < ActiveSupport::TestCase
  def imports
    JSON.parse(Rails.application.importmap.to_json(resolver: ApplicationController.helpers))["imports"]
  end

  test "no chart controller or d3 module is preloaded on a page that may have no chart" do
    preloaded = Rails.application.importmap.preloaded_module_paths(
      resolver: ApplicationController.helpers
    )
    charty = preloaded.grep(/d3-|internmap|chart_controller|lorenz_controller|treemap_controller/)
    assert_empty charty, "preload pulls these on every page regardless of lazy registration"
  end

  test "the chart controllers sit outside the eagerly loaded controllers namespace" do
    assert_empty imports.keys.grep(%r{^controllers/(chart|lorenz|treemap)_controller$}),
      "eagerLoadControllersFrom('controllers') fetches everything it finds under that prefix"
    assert_equal %w[charts/chart_controller charts/lorenz_controller charts/treemap_controller],
      imports.keys.grep(%r{^charts/}).sort
  end

  test "the charts namespace is registered lazily and the rest eagerly" do
    index = Rails.root.join("app/javascript/controllers/index.js").read
    assert_includes index, %(eagerLoadControllersFrom("controllers", application))
    assert_includes index, %(lazyLoadControllersFrom("charts", application))
  end

  test "every chart identifier used in a view resolves to a pinned charts module" do
    used = Dir[Rails.root.join("app/views/**/*.erb")].flat_map { |f|
      File.read(f).scan(/data-controller="([^"]*)"/).flatten
    }.flat_map(&:split).uniq & %w[chart lorenz treemap]
    assert_equal %w[chart lorenz treemap], used.sort, "a chart identifier moved or was removed"
    used.each do |name|
      assert imports.key?("charts/#{name}_controller"),
        "data-controller=\"#{name}\" would lazy load charts/#{name}_controller, which is not pinned"
    end
  end
end
