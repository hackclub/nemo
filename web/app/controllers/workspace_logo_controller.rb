class WorkspaceLogoController < ApplicationController
  def show
    url = WorkspaceLogo.url
    return head :not_found if url.blank?

    expires_in WorkspaceLogo::FOUND_FOR, public: false
    redirect_to url, allow_other_host: true, status: :found
  end
end
