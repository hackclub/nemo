module Admin
  class FlagsController < BaseController
    ROUTES = {
      "fire_engine" => [["/fd/cases", :path], ["/fd/members", :path],
                        ["and the search palette", :note]],
      "analytics" => [["/", :path], ["/channels", :path], ["/engine", :path]],
      "decisions" => [["/fd/decisions", :path], ["and the case-to-decision link", :note]]
    }.freeze

    def show
      @flags = Fd::Flag::KEYS.sort_by { |key| Fd::Flag.on?(key) ? 1 : 0 }
      @dark = Fd::Flag::KEYS.reject { |key| Fd::Flag.on?(key) }
      @losers = Fd::Flag::KEYS.index_with { |key| lose(key) }
      @flipped = Fd::Flag.where(key: Fd::Flag::KEYS).index_by(&:key)
      @names = Fd::Names.for(@flipped.values.filter_map(&:changed_by))
    end

    private

    def lose(key)
      Authz.who_holds(fd?(key) ? "case.read" : "channel.read").size
    end

    def fd?(key)
      %w[fire_engine decisions].include?(key.to_s)
    end

    def routes(key)
      ROUTES.fetch(key.to_s, [])
    end
    helper_method :routes
  end
end
