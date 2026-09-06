class WorkspaceLogoController < ApplicationController
  def show
    picture = WorkspaceLogo.image
    return head :not_found if picture.blank?

    expires_in WorkspaceLogo::FOUND_FOR, public: false
    send_data picture.body, type: picture.type, disposition: "inline"
  end
end
