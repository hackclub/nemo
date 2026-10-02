module Fd
  class FilesController < BaseController
    permit "case.read"

    FALLBACK = "application/octet-stream".freeze

    def show
      file = IntakeFile.find(params[:id])
      return head :not_found unless file.kept?

      body = IntakeFileBlob.bytes_for(file.stored_key)
      return head :not_found if body.nil?

      response.headers["Cache-Control"] = "private, max-age=300"
      send_data body,
        type: file.inline? ? file.mimetype : FALLBACK,
        filename: file.shown_name,
        disposition: file.inline? ? "inline" : "attachment"
    end
  end
end
