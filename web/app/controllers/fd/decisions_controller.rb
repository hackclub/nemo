module Fd
  class DecisionsController < BaseController
    VIEWS = {
      "all" => "All",
      "force" => "In force",
      "proposed" => "Proposed",
      "retired" => "Retired"
    }.freeze

    BANDS = {
      "force" => ["In force", "what FD does today"],
      "proposed" => ["Proposed", "waiting on a lead"],
      "retired" => ["Retired", "replaced, kept for the record"]
    }.freeze

    def index
      @view = VIEWS.key?(params[:view].to_s) ? params[:view].to_s : "all"
      @counts = counts
      @bands = bands
      @threads = DecisionThread.group(:decision_id).count
      @names = Names.for(people_named)
    end

    def show
      @decision = Decision.includes(:threads, :replacement).find(params[:id])
      @replaced = @decision.replaced.order(:retired_at).to_a
      @previous, @next = neighbours(@decision)
      @names = Names.for(named_on(@decision))
    end

    private

    def neighbours(decision)
      order = Decision.newest_first.pluck(:id)
      at = order.index(decision.id)
      [at.positive? ? order[at - 1] : nil, order[at + 1]]
    end

    def named_on(decision)
      [decision.proposed_by, decision.settled_by, decision.retired_by,
       *decision.threads.map(&:added_by)].compact.uniq
    end

    def counts
      tally = Decision.group(:state).count
      {
        "all" => tally.values.sum,
        "force" => tally.fetch("settled", 0),
        "proposed" => tally.fetch("proposed", 0),
        "retired" => tally.fetch("superseded", 0)
      }
    end

    def bands
      keys = @view == "all" ? BANDS.keys : [@view]
      keys.filter_map do |key|
        rows = listing(key).to_a
        [*BANDS.fetch(key), rows] if rows.any? || keys.one?
      end
    end

    def listing(key)
      scope = case key
      when "force" then Decision.in_force
      when "proposed" then Decision.unsettled
      else Decision.retired.includes(:replacement)
      end

      scope.newest_first
    end

    def people_named
      @bands.flat_map { |band| band.last }
        .flat_map { |decision| [decision.proposed_by, decision.settled_by, decision.retired_by] }
        .compact.uniq
    end
  end
end
