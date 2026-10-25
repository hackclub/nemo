module Fd
  class CasesController < BaseController
    permit "case.read", only: [:index, :show]

    before_action :load_pane, only: [:index, :show]
    permit "case.open", only: :create
    permit "case.categorise", on: -> { Case.find(params[:id]) }, only: :update

    TABS = %w[report people actions notes timeline].freeze

    def index
      @open_modal = params[:open] == "1"
      load_index
    end

    def show
      @case = Case.find(params[:id])

      family = @case.family_ids
      @threads = CaseThread.where(case_id: family).primary_first.to_a
      @participants = CaseParticipant.where(case_id: family).by_role.to_a
        .uniq { |person| [person.user_id, person.role] }
      @others = @participants.reject { |person| person.role == "subject" }
      @people = CasePeople.for(@participants, selected_user_id: params[:person])
      @reports = CaseReport.where(case_id: family).oldest_first.to_a
      @root_chat = CaseChat.root_for(@case, family) if @reports.empty?
      @actions = Action.where(case_id: family).oldest_first.to_a
      @live_actions = @actions.reject(&:reversed?)
      @thread_guards = ThreadGuard.for_case(family).newest_first.to_a
      @thread_locks = ThreadGuard.selectable_locks(family)
      @locks_logged = Action.thread_guards_logged_on(family)
      @guards_logged = Action.guards_logged_on(family)
      subjects = @case.subject_user_ids
      @action_standing = MemberGuard.standing_on(
        @people.selected&.user_id || (subjects.first if subjects.one?)
      )
      @siblings = @case.sibling_cases.includes(:subjects).oldest_first.to_a
      @duplicate_candidates = Case.candidates_for(@case, @siblings)
      @notes = Note.where(case_id: family).visible.recent_first.to_a
      @conversations = IntakeConversation.for_case(family).to_a
      @reachable_report_ids = @conversations.reject(&:closed?).map(&:report_id).to_set
      @thread = selected_thread(@reports)
      @thread_conversation = @conversations.find { |conversation| conversation.report_id == @thread&.id }
      @conversation_messages = IntakeMessage.tail([@thread_conversation&.id].compact)
      @conversation_count = IntakeMessage.count_for([@thread_conversation&.id].compact)
      @queued_replies = if @thread_conversation
        IntakeOutbox.where(conversation_id: @thread_conversation.id)
          .where(sent_at: nil).oldest_first.to_a
      else
        []
      end
      hidden_threads = CaseReport.threads_besides(@reports, @thread)
      @chat = CaseChat.tail(family, hidden_threads: hidden_threads)
      @earlier_count = CaseChat.earlier_than(family, @chat.size, hidden_threads: hidden_threads) +
        [@conversation_count - @conversation_messages.size, 0].max
      @standing_notes = Note.for_subjects(@participants.map(&:user_id)).visible.recent_first
        .group_by(&:subject_user_id)
      @thread_messages = ThreadMessage.for_threads(@threads).to_a
      @case_person = CasePerson.for(@people.selected, kase: @case, actions: @actions,
        notes: @notes, messages: @thread_messages)
      @cited_shares = IntakeShare.for_messages(@conversation_messages.map(&:id))
      @channels = ChannelNames.for(@threads.map(&:channel_id) + cited_channel_ids +
        @thread_guards.map(&:channel_id) + @thread_locks.map(&:channel_id) +
        @action_standing.map(&:channel_id) +
        @actions.filter_map { |action| action.details["channel_id"] } +
        Array(@pane_channels) +
        ChatChannels.ids(@chat, @conversation_messages, @queued_replies, @reports, @notes))
      @emoji = ChatEmoji.for(@chat, @conversation_messages, @queued_replies, @reports)
      @linked_cases = LinkedCases.for(
        ChatLinks.refs(@chat, @conversation_messages, @queued_replies, @reports, @notes)
      )
      @person_priors = Case.prior_counts_for(@participants.map(&:user_id))
      @assignees = @case.assignees.to_a
      @mentioned = @case.mentioned_but_unlogged(
        notes: @notes + @standing_notes.values.flatten, reports: @reports
      )
      @erased_entries = AuditEntry.erasures_for(case_id: family,
        note_ids: Note.where(case_id: family).ids).to_a
      @names = Names.for(page_ids)
      @timeline = CaseTimeline.for(
        @case,
        reports: @reports,
        actions: @actions,
        notes: @notes + @standing_notes.values_at(*@case.subject_user_ids).compact.flatten,
        participants: @participants,
        assignees: @assignees,
        erasures: @erased_entries,
        names: @names,
        channels: @channels,
      )
      @context = MemberContext.for(
        @case.subject_user_ids +
          @participants.map(&:user_id) +
          @siblings.flat_map(&:subject_user_ids)
      )
      @tab = params[:tab].presence_in(TABS) || (@case.resolved? ? "actions" : "report")
      @tab_counts = {
        "report" => @reports.size,
        "actions" => @actions.size,
        "notes" => @notes.size,
        "people" => @participants.size,
        "timeline" => @timeline.size
      }
      @flags = CaseFlags.for_case(@case, names: @names)
      @subject = @case.subject_user_ids.first
      @subject_priors = @subject ? Case.prior_count(@subject, within: Case::PRIOR_WINDOW) : 0
      @merge_into = @duplicate_candidates.find { |other| !other.resolved? }
      @open_reports = @reports.count { |report| !report.outcome_notified? }
    end

    def update
      kase = Case.find(params[:id])
      requested_category = params[:category_key].to_s
      unless InfractionCategory.active_key?(requested_category)
        field_error!(:category_key, "Select a category")
        return redirect_to(fd_case_path(kase, do: "category"))
      end
      previous_category = kase.category_key
      return redirect_to(fd_case_path(kase)) if previous_category == requested_category

      writing do
        kase.update!(category_key: requested_category)
        audit(kase, "categorised",
          before: { "category_key" => previous_category }, after: { "category_key" => requested_category })
      end

      redirect_to fd_case_path(kase), notice: "Case #{kase.id} marked #{requested_category.tr('_', ' ')}"
    end

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    def create
      subjects = requested_subjects

      error = validation_error(subjects)
      return render_error(error) if error

      kase = nil
      writing do
        kase = Case.create!(
          category_key: params[:category_key].presence,
          opened_by: current_account.user_id,
          opened_at: Time.current,
          source_app: Audit::SOURCE_APP
        )
        audit(kase, "opened")
        subjects.each { |id| audit(kase.add_subject!(id), "attached", entity_id: kase.id) }
        if params[:assign_to_me] == "1"
          audit(kase.assign!(current_account.user_id), "claimed", entity_id: kase.id)
        end
        write_opening(kase)
      end

      redirect_to fd_case_path(kase), notice: opened_notice(kase, subjects)
    end

    private

    def selected_thread(reports)
      reports.find { |report| report.id == params[:thread].to_i } || reports.last
    end

    def cited_channel_ids
      (@cited_shares || {}).values.flatten.map(&:source_channel_id).compact
    end

    def cited_authors
      (@cited_shares || {}).values.flatten.map(&:source_author_user_id).compact
    end

    def page_ids
      [
        @case.opened_by,
        @participants.map(&:user_id),
        @assignees.flat_map { |person| [person.user_id, person.assigned_by] },
        @reports.map(&:reporter_user_id),
        @actions.flat_map { |action| [action.target_user_id, action.decided_by, action.performed_by, action.reversed_by] },
        (@notes + @standing_notes.values.flatten).map(&:author),
        @siblings.flat_map(&:subject_user_ids),
        (@notes + @standing_notes.values.flatten).flat_map { |note| Mentions.ids(note.body) },
        @reports.flat_map { |report| Mentions.ids(report.body) },
        @root_chat&.author_user_id,
        ChatPeople.ids(@chat, @conversation_messages, @queued_replies, @reports),
        @thread_messages.map(&:author_user_id),
        @thread_messages.map(&:purged_by),
        @threads.map(&:added_by),
        @erased_entries.map(&:actor_user_id),
        cited_authors,
        Array(@pane_people)
      ]
    end

    def requested_subjects
      raw = params[:subject_user_ids].presence || [params[:subject_user_id]]
      Array(raw).map { |id| id.to_s.strip.delete_prefix("@").upcase }.reject(&:blank?).uniq
    end

    def preset_for(subjects)
      return [] if subjects.empty?

      names = Names.for(subjects)
      subjects.map do |id|
        { id: id, name: names[id], initial: names.member(id)&.initial || id[0] }
      end
    end

    def validation_error(subjects)
      unless subjects.all? { |id| id.match?(MEMBER_ID) }
        return "Not a Slack member ID"
      end
      if params[:category_key].present? && !InfractionCategory.active_key?(params[:category_key])
        return "Select a category"
      end
      return "Enter a description" if params[:body].to_s.strip.blank?
      if params[:body].to_s.strip.length > CaseChat::MAX_LENGTH
        return "Keep it under #{CaseChat::MAX_LENGTH} characters"
      end

      nil
    end

    def opened_notice(kase, subjects)
      return "Case #{kase.id} opened" if subjects.one?

      "Case #{kase.id} opened · #{subjects.size} subjects"
    end

    def write_opening(kase)
      CaseChat.create!(
        case_id: kase.id,
        author_user_id: current_account.user_id,
        body: Mentions.normalise(params[:body].to_s.strip),
        source_app: Audit::SOURCE_APP,
        mirrored_as: "card"
      )
    end

    def render_error(message)
      flash.now[:alert] = message
      @open_modal = true
      load_pane
      load_index
      render :index, status: :unprocessable_content
    end

    PANE_LIMIT = 60

    def load_pane
      requested_view = params[:view].presence || (action_name == "show" ? "attention" : nil)
      @pane_query = CaseQuery.new(params.merge(view: requested_view), viewer: current_account&.user_id)
      @pane_views = @pane_query.views
      @pane_params = @pane_query.to_params
      @pane_cases = @pane_query.relation
        .includes(:subjects, :assignees, :reports, :actions, case_tags: :tag)
        .limit(PANE_LIMIT).to_a
      @pane_priors = Case.prior_counts_for(@pane_cases.flat_map(&:subject_user_ids))
      @pane_violations = Case.violations_for(@pane_cases.map(&:id))
      previews = QueuePreviews.for(@pane_cases)
      @cited_words = previews.cited
      @attachment_counts = previews.attachment_counts
      @case_roots = previews.roots
      @pane_reachable_report_ids = IntakeConversation.open
        .where(report_id: @pane_cases.flat_map { |kase| kase.reports.map(&:id) })
        .pluck(:report_id).to_set
      @pane_people = @pane_cases.flat_map { |kase|
        kase.subject_user_ids + kase.assignee_user_ids + [kase.opened_by] +
          kase.reports.map(&:reporter_user_id)
      } + previews.user_ids
      @pane_channels = previews.channel_ids
    end

    def load_index
      @names = Names.for(Array(@pane_people))
      @channels = ChannelNames.for(Array(@pane_channels))
      @subject_preset = preset_for(requested_subjects)
    end
  end
end
