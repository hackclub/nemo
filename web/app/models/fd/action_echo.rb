module Fd
  class ActionEcho
    def self.write!(kase, action, by:)
      CaseChat.create!(
        case_id: kase.id,
        author_user_id: by,
        body: body_for(action),
        source_app: Audit::SOURCE_APP,
        mirrored_as: (SlackPost.claimable?(kase.id, by) ? "user" : nil)
      )
    end

    def self.body_for(action)
      target = action.aimed_at_member? ? "<@#{action.target_user_id}>" : "a thread"
      label = FdHelper::ACTION_LABELS.fetch(action.type_key) { action.type_key.tr("_", " ").capitalize }
      lines = ["#{label} logged on #{target}"]
      lines[-1] += ": #{action.reason}" if action.reason.presence
      lines << "How it was solved: #{action.resolution_note}" if action.resolution_note.presence
      lines.join("
")
    end
  end
end
