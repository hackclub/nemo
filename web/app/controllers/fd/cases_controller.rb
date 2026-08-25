module Fd
  class CasesController < BaseController
    permit "case.open", only: [:create, :update]

    TABS = %w[report evidence actions notes people].freeze
    PER_PAGE = 50

    def index
      @open_modal = params[:open] == "1"
      load_queue
    end

    def show
      @case = Case.find(params[:id])
      return render_drawer if turbo_frame_request_id == "case-drawer"

      family = @case.family_ids
      @threads = CaseThread.where(case_id: family).primary_first.to_a
      @participants = CaseParticipant.where(case_id: family).by_role.to_a
        .uniq { |person| [person.user_id, person.role] }
      @others = @participants.reject { |person| person.role == "subject" }
      @people = CasePeople.for(@participants, asked: params[:person])
      @reports = CaseReport.where(case_id: family).oldest_first.to_a
      @actions = Action.where(case_id: family).oldest_first.to_a
      @live_actions = @actions.reject(&:reversed?)
      @siblings = @case.sibling_cases.includes(:subjects).oldest_first.to_a
      @duplicate_candidates = Case.candidates_for(@case, @siblings)
      @notes = Note.where(case_id: family).visible.recent_first.to_a
      @conversations = IntakeConversation.for_case(family).to_a
      @thread = chosen_thread(@reports)
      @thread_conversation = @conversations.find { |one| one.report_id == @thread&.id }
      @conversation_said = IntakeMessage.tail([@thread_conversation&.id].compact)
      @queued = if @thread_conversation
        IntakeOutbox.where(conversation_id: @thread_conversation.id)
          .where(sent_at: nil).oldest_first.to_a
      else
        []
      end
      @chat = CaseChat.tail(family)
      @earlier_chat = CaseChat.earlier_than(family, @chat.size)
      @standing_notes = Note.for_subjects(@participants.map(&:user_id)).visible.recent_first
        .group_by(&:subject_user_id)
      @thread_messages = ThreadMessage.for_threads(@threads).to_a
      @case_person = CasePerson.for(@people.chosen, kase: @case, actions: @actions,
        notes: @notes, messages: @thread_messages)
      @thread_list = CaseThreads.for(@threads, actions: @actions,
        messages: @thread_messages, asked: params[:thread])
      @citations = CaseCitation.where(case_id: family).oldest_first
        .index_by(&:thread_message_id)
      @flagged_messages = @thread_messages.select { |said| @citations.key?(said.id) }
      @cited_by = @actions.select(&:cites?).group_by(&:cites_message_id)
      @cited_messages = cited_messages
      @channels = ChannelNames.for(@threads.map(&:channel_id) +
        @cited_messages.values.map(&:channel_id))
      @said_counts = @thread_messages.group_by(&:author_user_id).transform_values(&:size)
      @person_priors = Case.prior_counts_for(@participants.map(&:user_id))
      @assignees = @case.assignees.to_a
      @decisions = Flag.on?(:decisions) ? Decision.order(:title).to_a : []
      @mentioned = @case.mentioned_but_unlogged(
        notes: @notes + @standing_notes.values.flatten, reports: @reports
      )
      @erasures = AuditEntry.erasures_for(case_id: family,
        note_ids: Note.where(case_id: family).ids).to_a
      @links = AuditEntry.decision_links_for(case_id: family).to_a
      @decision_titles = Decision.where(id: linked_decision_ids).pluck(:id, :title).to_h
      @names = Names.for(page_ids)
      @timeline = CaseTimeline.for(
        @case,
        reports: @reports,
        actions: @actions,
        notes: @notes + @standing_notes.values_at(*@case.subject_user_ids).compact.flatten,
        participants: @participants,
        assignees: @assignees,
        erasures: @erasures,
        links: @links,
        decisions: @decision_titles,
        names: @names,
      )
      @context = MemberContext.for(
        @case.subject_user_ids +
          @participants.map(&:user_id) +
          @siblings.flat_map(&:subject_user_ids)
      )
      @tab = params[:tab].presence_in(TABS) || (@case.resolved? ? "actions" : "report")
      @tab_counts = {
        "evidence" => @thread_messages.size.positive? ? @thread_messages.size : @thread_list.size,
        "actions" => @actions.size,
        "notes" => @notes.size,
        "people" => @participants.size
      }
      @flags = CaseFlags.for_case(@case, names: @names)
      @subject = @case.subject_user_ids.first
      @subject_priors = @subject ? Case.prior_count(@subject, within: Case::PRIOR_WINDOW) : 0
      @merge_into = @duplicate_candidates.find { |other| !other.resolved? }
      @open_reports = @reports.count { |report| !report.told_of_outcome? }
      @missing = missing_on(@case, @subject, @threads)
      @guesses = @missing.any? ? CaseFlags.channel_guesses(@reports) : []
    end

    def update
      kase = Case.find(params[:id])
      wanted = params[:category_key].to_s
      unless Case::CATEGORIES.include?(wanted)
        return redirect_to(fd_case_path(kase), alert: "pick a category from the list")
      end
      if kase.category_key.present?
        return redirect_to(fd_case_path(kase), alert: "this case already has a category")
      end

      was = kase.category_key
      writing do
        kase.update!(category_key: wanted)
        audit(kase, "categorised",
          before: { "category_key" => was }, after: { "category_key" => wanted })
      end

      redirect_to fd_case_path(kase), notice: "case #{kase.id} is #{wanted.tr('_', ' ')}"
    end

    MEMBER_ID = /\A[UW][A-Z0-9]{2,}\z/

    def create
      subjects = asked_subjects
      @open_for_subject = open_cases_for(subjects)

      problem = objection(subjects)
      return refuse(problem) if problem
      return refuse(already_open_warning) if warn_about_open_case?

      kase = nil
      writing do
        kase = Case.create!(
          category_key: params[:category_key].presence,
          opened_by: current_staff.user_id,
          opened_at: Time.current,
          source_app: Audit::SOURCE_APP
        )
        audit(kase, "opened")
        subjects.each { |id| audit(kase.add_subject!(id), "attached", entity_id: kase.id) }
        if params[:assign_to_me] == "1"
          audit(kase.assign!(current_staff.user_id), "claimed", entity_id: kase.id)
        end
        write_first_note(kase)
      end

      redirect_to fd_case_path(kase), notice: opened_notice(kase, subjects)
    end

    private

    def chosen_thread(reports)
      reports.find { |report| report.id == params[:thread].to_i } || reports.last
    end

    def render_drawer
      @reports = @case.reports.oldest_first.to_a
      @names = Names.for(@case.subject_user_ids + @case.assignee_user_ids + [@case.opened_by] +
        @reports.map(&:reporter_user_id))
      @flags = CaseFlags.for_case(@case, names: @names)
      siblings = @case.sibling_cases.includes(:subjects).oldest_first.to_a
      @merge_into = Case.candidates_for(@case, siblings).find { |other| !other.resolved? }
      render "drawer"
    end

    def cited_messages
      wanted = @cited_by.keys - @thread_messages.map(&:id)
      held = @thread_messages.index_by(&:id)
      held.merge(ThreadMessage.where(id: wanted).index_by(&:id))
    end

    def page_ids
      [
        @case.opened_by,
        @participants.map(&:user_id),
        @assignees.flat_map { |person| [person.user_id, person.assigned_by] },
        @reports.map(&:reporter_user_id),
        @actions.flat_map { |a| [a.target_user_id, a.decided_by, a.performed_by, a.reversed_by] },
        (@notes + @standing_notes.values.flatten).map(&:author),
        @siblings.flat_map(&:subject_user_ids),
        (@notes + @standing_notes.values.flatten).flat_map { |note| Mentions.ids(note.body) },
        @reports.flat_map { |report| Mentions.ids(report.body) },
        @thread_messages.map(&:author_user_id),
        @thread_messages.map(&:purged_by),
        @citations.values.map(&:flagged_by),
        @threads.map(&:added_by),
        @erasures.map(&:actor_user_id),
        @links.map(&:actor_user_id)
      ]
    end

    def linked_decision_ids
      @links.flat_map { |row| [row.before, row.after] }
        .compact.filter_map { |values| values["followed_decision_id"] }.uniq
    end

    def asked_subjects
      raw = params[:subject_user_ids].presence || [params[:subject_user_id]]
      Array(raw).map { |id| id.to_s.strip.delete_prefix("@").upcase }.reject(&:blank?).uniq
    end

    def preset_for(subjects)
      return [] if subjects.empty?

      known = Names.for(subjects)
      subjects.map do |id|
        { id: id, name: known[id], initial: known.member(id)&.initial || id[0] }
      end
    end

    def missing_on(kase, subject, threads)
      return [] if kase.resolved?

      needed = { subject: subject.nil?, violation: kase.category_key.blank?,
                 evidence: threads.empty? }
      needed.select { |_what, missing| missing }.keys
    end

    def open_cases_for(subjects)
      return [] if subjects.empty?

      Case.unresolved.with_any_subject(subjects).includes(:subjects).oldest_first.to_a
    end

    def objection(subjects)
      unless subjects.all? { |id| id.match?(MEMBER_ID) }
        return "that does not look like a Slack member id"
      end
      if params[:category_key].present? && !Case::CATEGORIES.include?(params[:category_key])
        return "pick a category from the list"
      end

      nil
    end

    def warn_about_open_case?
      @open_for_subject.any? && params[:separate] != "1"
    end

    def already_open_warning
      caught = (@open_for_subject.flat_map(&:subject_user_ids) & asked_subjects).uniq
      who = Names.for(caught).list(caught)
      numbers = @open_for_subject.map { |kase| "##{kase.id}" }.to_sentence
      "#{who} already #{caught.many? ? 'have' : 'has'} an open case, #{numbers}. " \
        "Add to that one, or open a new case."
    end

    def opened_notice(kase, subjects)
      return "case #{kase.id} opened" if subjects.one?

      "case #{kase.id} opened, about #{subjects.size} people"
    end

    def write_first_note(kase)
      body = Mentions.normalise(params[:body].to_s.strip)
      return if body.blank?

      note = Note.create!(case_id: kase.id, body: body, author: current_staff.user_id)
      audit(note, "noted")
    end

    def refuse(message)
      flash.now[:alert] = message
      @open_modal = true
      load_queue
      render :index, status: :unprocessable_content
    end

    def load_queue
      @query = CaseQuery.new(params, viewer: current_staff&.user_id)
      @page = [params[:page].to_i, 1].max
      found = @query.relation.includes(:subjects, :assignees, :reports)
        .offset((@page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
      @more = found.size > PER_PAGE
      @cases = found.first(PER_PAGE)
      case_ids = @cases.map(&:id)
      lone_subjects = @cases.filter_map { |kase| kase.subject_user_ids.first if kase.subject_user_ids.one? }
      @prior_counts = Case.prior_counts_for(lone_subjects)
      @thread_counts = Case.thread_message_counts_for(case_ids)
      @thread_channels = Case.thread_channels_for(case_ids)
      @channels = ChannelNames.for(@thread_channels.values.flatten)
      @stats = QueueStats.load
      @total_count = @stats.total
      @views = @query.views
      @subject_preset = preset_for(asked_subjects)
      @names = Names.for(@cases.flat_map { |kase|
        kase.subject_user_ids + kase.assignee_user_ids + [kase.opened_by] +
          kase.reports.map(&:reporter_user_id)
      })
      @open_for_subject ||= []
      @flags = CaseFlags.for_queue
    end
  end
end
