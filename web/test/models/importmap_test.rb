require "test_helper"

class ImportmapTest < ActiveSupport::TestCase
  def imports
    JSON.parse(Rails.application.importmap.to_json(resolver: ApplicationController.helpers))["imports"]
  end

  test "no chart controller or d3 module is preloaded on a page that may have no chart" do
    preloaded = Rails.application.importmap.preloaded_module_paths(
      resolver: ApplicationController.helpers
    )
    charty = preloaded.grep(%r{d3-|internmap|^charts/})
    assert_empty charty, "preload pulls these on every page regardless of lazy registration"
  end

  test "the chart controllers sit outside the eagerly loaded controllers namespace" do
    assert_empty imports.keys.grep(%r{^controllers/(chart|hbars|lorenz|parts|scatter|treemap)_controller$}),
      "eagerLoadControllersFrom('controllers') fetches everything it finds under that prefix"
    assert_equal %w[charts/chart_controller charts/hbars_controller
                    charts/lorenz_controller charts/parts_controller
                    charts/scatter_controller charts/squarify
                    charts/treemap_controller],
      imports.keys.grep(%r{^charts/}).sort
  end

  test "a charts module that is not a controller is never registered as one" do
    index = Rails.root.join("app/javascript/controllers/index.js").read
    pattern = index[/\/\^charts\\\/\.\*_controller\$\//]
    assert pattern, "the lazy registration pattern moved"
    assert_no_match(/_controller$/, "charts/squarify",
      "squarify is a plain module, so the registration pattern must skip it")
  end

  test "the charts namespace is registered lazily and the rest eagerly" do
    index = Rails.root.join("app/javascript/controllers/index.js").read
    assert_includes index, %(eagerLoadControllersFrom("controllers", application))
    assert_no_match(/eagerLoadControllersFrom\(\s*"charts"/, index,
      "charts carry d3, so they must not load on pages that draw nothing")
    assert_match(/\^charts\\\/\.\*_controller\$/, index,
      "the lazy registration must find its candidates in the charts namespace")
    assert_no_match(/lazyLoadControllersFrom/, index,
      "the prefix loader tries charts/<name>_controller for every identifier on the page")
  end

  test "every chart identifier used in a view resolves to a pinned charts module" do
    used = Dir[Rails.root.join("app/views/**/*.erb")].flat_map { |f|
      File.read(f).scan(/data-controller="([^"]*)"/).flatten
    }.flat_map(&:split).uniq & %w[chart hbars lorenz parts scatter treemap]
    assert_equal %w[chart lorenz parts scatter treemap], used.sort,
      "a chart identifier moved or was removed"
    used.each do |name|
      assert imports.key?("charts/#{name}_controller"),
        "data-controller=\"#{name}\" would lazy load charts/#{name}_controller, which is not pinned"
    end
  end
end
