class WorkspaceLogoJob < ApplicationJob
  queue_as :default

  def perform
    WorkspaceLogo.refresh
  end
end
