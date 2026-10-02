module Api
  class App < ApplicationRecord
    self.table_name = "api.app"

    MAX_NAME = 60
    MAX_BLURB = 500
    SHORTEST_BLURB = 10

    class TooThin < StandardError; end
    class Unnamed < StandardError; end

    has_many :tokens, class_name: "Api::Token", foreign_key: :app_id, inverse_of: :app
    has_one :approval, class_name: "Api::Approval", foreign_key: :app_id, inverse_of: :app

    scope :live, -> { where(retired_at: nil) }

    def self.for_owner(user_id)
      live.where(owner_user_id: user_id).order(:name)
    end

    def self.answering
      live.where(id: Approval.live.select(:app_id)).order(:name)
    end

    def self.register!(owner_user_id, name:, blurb:)
      said = name.to_s.strip
      covers = blurb.to_s.strip
      raise Unnamed if said.empty?
      raise TooThin if covers.length < SHORTEST_BLURB

      create!(owner_user_id: owner_user_id, name: said.first(MAX_NAME),
        blurb: covers.first(MAX_BLURB), slug: slug_for(said))
    end

    def self.slug_for(name)
      base = name.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
      base = "app" if base.empty?
      taken = where("slug LIKE ?", "#{base}%").pluck(:slug)
      return base unless taken.include?(base)

      (2..).each { |n| return "#{base}-#{n}" unless taken.include?("#{base}-#{n}") }
    end

    def answering? = Approval.held?(id)

    def retired? = retired_at.present?

    def retire!(by:)
      transaction do
        update!(retired_at: Time.current)
        AccessRequest.pending.where(app_id: id).each(&:withdraw!)
        Approval.revoke!(id, by: by)
        tokens.live.find_each { |token| token.revoke!(by: by) }
      end
    end
  end
end
