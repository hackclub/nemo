module Fd
  class LinkVerdictsController < BaseController
    permit "link.verdict"

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/
    SAID = { recorded: "verdict recorded", changed: "verdict changed", unchanged: "verdict unchanged" }.freeze

    def create
      problem = objection
      return redirect_to(back, alert: problem) if problem

      outcome = nil
      writing { outcome = record }
      redirect_to back, notice: SAID.fetch(outcome)
    end

    private

    def pair = LinkVerdict.pair(params[:a].to_s.strip.upcase, params[:b].to_s.strip.upcase)

    def verdict = params[:verdict].to_s

    def note = params[:note].to_s.strip.presence

    def objection
      a, b = pair
      return "pick two accounts" unless a.match?(MEMBER_ID) && b.match?(MEMBER_ID) && a != b
      return "pick a verdict" unless LinkVerdict::VERDICTS.key?(verdict)

      nil
    end

    def record
      a, b = pair
      held = LinkVerdict.lock.find_by(a_user_id: a, b_user_id: b)
      kept_note = note || held&.note
      return :unchanged if held && held.verdict == verdict && held.note == kept_note

      before = held&.said
      row = held || LinkVerdict.new(a_user_id: a, b_user_id: b)
      row.update!(verdict: verdict, decided_by: current_account.user_id, decided_at: Time.current, note: kept_note)
      audit(row, row.verb, before: before, after: row.said.merge("a_user_id" => a, "b_user_id" => b),
        subject_user_id: b)
      held ? :changed : :recorded
    end

    def back
      asked = params[:back].to_s
      asked.start_with?("/fd/") ? asked : fd_links_path
    end
  end
end
