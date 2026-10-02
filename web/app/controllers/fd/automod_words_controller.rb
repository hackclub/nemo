module Fd
  class AutomodWordsController < BaseController
    permit "app.configure"

    LONGEST = 80

    def create
      problem = objection
      return refuse(problem) if problem

      word = nil
      writing do
        word = AutomodWord.add!(word: said, by: current_account.user_id,
          match_mode: match_mode, effect: effect,
          category_key: chosen_category, note: params[:note])
        audit(word, "added", after: { "match_mode" => word.match_mode,
          "effect" => word.effect, "category_key" => word.category_key })
      end

      redirect_to fd_configuration_path, notice: "added to the automod list"
    rescue ActiveRecord::RecordNotUnique
      refuse("already on the list")
    end

    def destroy
      word = AutomodWord.active.find_by(id: params[:id])
      return refuse("not on the list") if word.nil?

      writing do
        word.retire!(by: current_account.user_id)
        audit(word, "removed", before: { "active" => true }, after: { "active" => false })
      end

      redirect_to fd_configuration_path, notice: "removed from the automod list"
    end

    private

    def said
      params[:word].to_s.strip
    end

    def match_mode
      asked = params[:match_mode].to_s
      AutomodWord::MATCHES.include?(asked) ? asked : AutomodWord::WORD
    end

    def effect
      asked = params[:effect].to_s
      AutomodWord::SHIPPED_EFFECTS.include?(asked) ? asked : AutomodWord::FLAG
    end

    def chosen_category
      asked = params[:category_key].to_s
      asked if Case::CATEGORIES.include?(asked)
    end

    def objection
      return "no word given" if said.blank?
      return "word is over #{LONGEST} characters" if said.length > LONGEST
      return nil unless match_mode == AutomodWord::REGEX

      Regexp.new(said)
      nil
    rescue RegexpError => failure
      "that regex does not compile: #{failure.message}"
    end

    def refuse(why)
      redirect_to fd_configuration_path, alert: why
    end
  end
end
