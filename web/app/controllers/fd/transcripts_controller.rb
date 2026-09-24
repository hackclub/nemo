module Fd
  class TranscriptsController < BaseController
    def show
      kept = ThreadTranscript.for_key(params[:key])
      return head :not_found if kept.nil?

      audit(kept, "read", after: { "channel_id" => kept.channel_id,
                                   "thread_ts" => kept.thread_ts })

      response.headers["Cache-Control"] = "private, no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Referrer-Policy"] = "no-referrer"
      send_data kept.body, type: "text/plain; charset=utf-8", disposition: "inline"
    end
  end
end
