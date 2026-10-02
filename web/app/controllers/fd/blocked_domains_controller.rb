module Fd
  class BlockedDomainsController < BaseController
    permit "app.configure"

    LONGEST = 253

    def create
      return refuse!("member.deactivate") if effect == BlockedDomain::DEACTIVATE &&
        !current_account&.may?("member.deactivate")

      problem = objection
      return refuse(problem) if problem

      writing do
        one = BlockedDomain.add!(domain: said, by: current_account.user_id,
          match_mode: match_mode, effect: effect, note: params[:note])
        audit(one, "added", after: { "domain" => one.domain, "match_mode" => one.match_mode,
          "effect" => one.effect })
      end

      redirect_to here, notice: "#{said} is on the list, set to #{effect}"
    rescue ActiveRecord::RecordNotUnique
      refuse("already on the list")
    end

    def destroy
      one = BlockedDomain.active.find_by(id: params[:id])
      return refuse("not on the list") if one.nil?

      writing do
        one.retire!(by: current_account.user_id)
        audit(one, "removed", before: { "active" => true }, after: { "active" => false })
      end

      redirect_to here, notice: "#{one.domain} is off the list"
    end

    private

    def here(**over) = fd_configuration_path(tab: "domains", **over)

    def said = params[:domain].to_s.strip.downcase.delete_prefix("@")

    def match_mode
      asked = params[:match_mode].to_s
      BlockedDomain::MATCHES.include?(asked) ? asked : BlockedDomain::EXACT
    end

    def effect
      asked = params[:effect].to_s
      BlockedDomain::EFFECTS.include?(asked) ? asked : BlockedDomain::FLAG
    end

    def overridden? = params[:anyway].present?

    def objection
      return "no domain given" if said.blank?
      return "a domain is under #{LONGEST} characters" if said.length > LONGEST
      return "#{said} is not a domain" unless BlockedDomain.shape?(said)
      return nil if overridden?

      crowd = BlockedDomain.people_on(said, match_mode: match_mode)
      return nil unless BlockedDomain.too_many?(crowd)

      wrong!(:domain, "#{said} is on #{helpers.pluralize(crowd, 'account')} already", said)
    end

    def refuse(why)
      redirect_to here(do: "domain"), alert: (why unless flash[:wrong])
    end
  end
end
