module Admin
  class FlagsController < BaseController
    ROUTES = {
      "fire_engine" => [["/fd/cases", :path], ["/fd/members", :path],
                        ["and the search palette", :note]],
      "analytics" => [["/", :path], ["/channels", :path], ["/engine", :path]]
    }.freeze

    def show
      @flags = Fd::Flag::LISTED.sort_by { |key| Fd::Flag.on?(key) ? 1 : 0 }
      @dark = Fd::Flag::LISTED.reject { |key| Fd::Flag.on?(key) }
      @losers = Fd::Flag::LISTED.index_with { |key| clear_flag(key) }
      @flipped = Fd::Flag.where(key: Fd::Flag::LISTED).index_by(&:key)
      @names = Fd::Names.for(@flipped.values.filter_map(&:changed_by))
    end

    private

    def clear_flag(key)
      Authz.holders_of(fd?(key) ? "case.read" : "channel.read").size
    end

    def fd?(key)
      key.to_s == "fire_engine"
    end

    def routes(key)
      ROUTES.fetch(key.to_s, [])
    end
    helper_method :routes
  end
end
