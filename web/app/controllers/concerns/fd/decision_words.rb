module Fd
  module DecisionWords
    extend ActiveSupport::Concern

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
  end
end
