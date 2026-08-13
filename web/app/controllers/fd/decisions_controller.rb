module Fd
  class DecisionsController < BaseController
    VIEWS = {
      "all" => "All",
      "force" => "In force",
      "proposed" => "Proposed",
      "retired" => "Retired"
    }.freeze

    BANDS = {
      "force" => "In force",
      "proposed" => "Proposed",
      "retired" => "Retired"
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
      @messages = ThreadMessage.for_threads(@decision.threads).to_a.group_by(&:coordinates)
      @names = Names.for(named_on(@decision) + @messages.values.flatten.map(&:author_user_id))
    end

    def create
      problem = missing_words
      return redirect_to(fd_decisions_path, alert: problem) if problem

      decision = Decision.new(written.merge(proposed_by: current_staff.user_id))

      writing do
        decision.save!
        audit(decision, "proposed")
      end

      redirect_to fd_decision_path(decision), notice: "written down"
    rescue ActiveRecord::RecordNotUnique
      redirect_to fd_decisions_path, alert: "there is already a decision called that"
    end

    def update
      decision = Decision.find(params[:id])
      problem = missing_words || settled_already(decision)
      return redirect_to(fd_decision_path(decision), alert: problem) if problem

      writing do
        decision.update!(written)
        audit(decision, "amended")
      end

      redirect_to fd_decision_path(decision), notice: "reworded"
    rescue ActiveRecord::RecordNotUnique
      redirect_to fd_decision_path(params[:id]), alert: "there is already a decision called that"
    end

    def destroy
      decision = Decision.find(params[:id])
      problem = not_droppable(decision)
      return redirect_to(fd_decision_path(decision), alert: problem) if problem

      writing do
        audit(decision, "dropped", before: { "title" => decision.title,
          "statement" => decision.statement }, after: nil)
        decision.drop!
      end

      redirect_to fd_decisions_path, notice: "dropped, it was never the rule"
    end

    private

    def written
      {
        title: params[:title],
        statement: params[:statement],
        category_key: Case::CATEGORIES.include?(params[:category_key]) ? params[:category_key] : nil,
        reasons: params[:reasons].to_s.split("\n")
      }
    end

    def missing_words
      return "give it a name" if params[:title].blank?

      "say what FD does from now on" if params[:statement].blank?
    end

    def settled_already(decision)
      return nil if decision.proposed?

      "decision #{decision.id} is settled, amend it rather than editing it"
    end

    def not_droppable(decision)
      return "a settled decision is superseded, never dropped" unless decision.droppable?
      return nil if decision.proposed_by == current_staff.user_id

      "@#{decision.proposed_by} proposed that, so only they can drop it"
    end

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
        [BANDS.fetch(key), rows] if rows.any? || keys.one?
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
