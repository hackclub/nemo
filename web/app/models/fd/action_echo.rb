module Fd
  class ActionEcho
    def self.write!(kase, actions, by:)
      CaseChat.create!(
        case_id: kase.id,
        author_user_id: by,
        body: body_for(actions),
        source_app: Audit::SOURCE_APP,
        mirrored_as: (SlackPost.claimable?(kase.id, by) ? "user" : nil)
      )
    end

    def self.body_for(actions)
      actions = Array(actions)
      action = actions.first
      target = action.targets_member? ? "<@#{action.target_user_id}>" : "a thread"
      label = actions.map do |one|
        FdHelper::ACTION_LABELS.fetch(one.type_key) { one.type_key.tr("_", " ").capitalize }
      end.join(", ")
      lines = ["#{label} logged on #{target}"]
      lines[-1] += ": #{action.reason}" if action.reason.presence
      lines << "How Was This Solved? #{action.solution}" if action.solution.presence
      lines.join("
")
    end
  end
end
