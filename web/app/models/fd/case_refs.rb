module Fd
  module CaseRefs
    PATTERN = %r{(?<![\w#&/])#(\d{3,6})(?!\w)}
    SPLIT = %r{((?<![\w#&/])#\d{3,6}(?!\w))}
    REF = /\A#(\d+)\z/

    def self.ids(text)
      text.to_s.scan(PATTERN).flatten.map(&:to_i).uniq
    end

    def self.linked(text)
      text = text.to_s
      wanted = ids(text)
      return ERB::Util.html_escape(text) if wanted.empty?

      existing = Case.where(id: wanted).pluck(:id).to_set
      helpers = ActionController::Base.helpers
      parts = text.split(SPLIT).map do |piece|
        case_id = piece[REF, 1]&.to_i
        next piece unless case_id && existing.include?(case_id)

        helpers.link_to(piece, Rails.application.routes.url_helpers.fd_case_path(case_id), class: "lnk")
      end
      helpers.safe_join(parts)
    end
  end
end
