# Mnemosyne audit and fix plan

Date: 12 September 2026. Reviewed revision: `8d903bf`.

28 concrete findings are enumerated below. This is a broad source audit with isolated reproductions, not a claim that every possible bug has been discovered. No application behavior was changed.

## Evidence and limits

- Reviewed cross-layer paths in Rails controllers/models/templates, Stimulus controllers/charts/styles, the Slack bot, ingestion/archive code, proxy and warehouse SQL. The report concentrates on reproducible defects and explicit mismatches between producers and consumers.
- Existing Python suite: **381 passed in 15.73 seconds**. This used a temporary Python 3.13 environment with compatible test dependencies; it was not a frozen-lockfile environment. These tests do not prove the new findings are covered.
- Additional isolated checks reproduced seven JavaScript defects, two pipeline/proxy defects, the new-channel Ruby clamp exception and the eight-day inclusive interval. The retained reproduction scripts print current behavior alongside expected behavior; they are diagnostic scripts, not newly installed CI tests.
- Rails integration/system tests and dbt/PostgreSQL execution were not available locally: system Ruby is 2.6.10, the lockfile requires Bundler 4.0.13, app gems are absent, and Docker/PostgreSQL tooling was not present. No live credentials or production records were used.
- A temporary local component fixture was served successfully, but the in-app browser timed out reaching it. **No screenshot-based or full-app visual verification was completed.** Findings about visual behavior are supported by source paths/generated markup, with browser verification specified in their acceptance checks.
- “Traced” means the triggering code path was inspected; it does not mean an end-to-end request or a concurrent database transaction was executed. Concurrency and SQL findings specifically need the listed integration checks.

P1: prioritize before relying on affected permissions, messages, case history or metrics. P2: functional/visual correctness work after the critical paths.

## Enumerated findings

### 01. [P1] Channel treemap reveals channels outside the viewer’s access

**Evidence:** Traced.

A signed-in account with access to only public/shared channels can load /channels. The table uses Channels::Audience, but the treemap calls MartChannelMomentum.top without channel_ids and embeds every selected channel’s name, message totals and prior totals in HTML. The mart also has no audience restriction. This can reveal restricted channels even when their detail pages are blocked.

**Code:** [web/app/controllers/channels_controller.rb:60](/Volumes/STORAGE/code/nemo/web/app/controllers/channels_controller.rb:60), [web/app/views/channels/_momentum.html.erb:2](/Volumes/STORAGE/code/nemo/web/app/views/channels/_momentum.html.erb:2).

**Fix:** Filter the treemap through the same audience relation before serializing it. Recompute scoped ranks, totals and shares, or explicitly document and authorize any workspace aggregate separately. Review the channel-band aggregate on the same page against the intended aggregate-access policy.

**Acceptance check:** As an ordinary account, grant access to A and deny B; make B a top channel. B’s name and per-channel counts must be absent from HTML and chart data. Verify direct detail access remains denied.

### 02. [P1] Accepting a mention with Enter also sends the unfinished message

**Evidence:** Reproduced in isolated JavaScript.

Type @al in the composer and press Enter on a suggestion. mention#keys inserts the mention and closes results; chat#keys then sees a hidden picker and calls requestSubmit on the same event. It ignores defaultPrevented. The isolated reproduction submits once when it should submit zero times. This also applies when the composer is aimed at a reporter.

**Code:** [web/app/views/fd/cases/_chat.html.erb:70](/Volumes/STORAGE/code/nemo/web/app/views/fd/cases/_chat.html.erb:70), [web/app/javascript/controllers/chat_controller.js:46](/Volumes/STORAGE/code/nemo/web/app/javascript/controllers/chat_controller.js:46), [web/app/javascript/controllers/mention_controller.js:145](/Volumes/STORAGE/code/nemo/web/app/javascript/controllers/mention_controller.js:145).

**Fix:** Give one handler ownership of Enter. Respect defaultPrevented or explicitly stop the action chain after accepting a mention.

**Acceptance check:** Enter accepts a mention without sending; a subsequent Enter sends exactly once. Repeat in internal, signed-reporter and anonymous-reporter modes.

### 03. [P1] IME composition can submit messages prematurely

**Evidence:** Reproduced in isolated JavaScript.

While composing Japanese, Chinese or another IME input, Enter can confirm composition. The message handlers do not check isComposing and interpret that Enter as Send. Passing isComposing=true to the actual chat handler triggers submission.

**Code:** [web/app/javascript/controllers/chat_controller.js:46](/Volumes/STORAGE/code/nemo/web/app/javascript/controllers/chat_controller.js:46), [web/app/javascript/controllers/mention_controller.js:121](/Volumes/STORAGE/code/nemo/web/app/javascript/controllers/mention_controller.js:121).

**Fix:** Ignore composing keyboard events in send, picker and shortcut handlers; use composition lifecycle handling where required by supported browsers.

**Acceptance check:** Confirm an IME candidate with Enter: no message is sent. Once composition ends, normal Enter and Shift+Enter retain their intended behavior.

### 04. [P2] Absolute date filters are unusable and accept incompatible values

**Evidence:** Reproduced input selection; backend path traced.

Choose Created or Last post → is before/is after. Both the template and controller use number inputs for every date field, preventing ISO-date entry. The server accepts either integers or Date objects independent of the operator: an integer may become an invalid timestamp comparison, and an ISO date supplied to within/before_days reaches Date#to_i, which is undefined.

**Code:** [web/app/javascript/controllers/conditions_controller.js:56](/Volumes/STORAGE/code/nemo/web/app/javascript/controllers/conditions_controller.js:56), [web/app/views/channels/_condition_row.html.erb:30](/Volumes/STORAGE/code/nemo/web/app/views/channels/_condition_row.html.erb:30), [web/app/models/channels/filter.rb:151](/Volumes/STORAGE/code/nemo/web/app/models/channels/filter.rb:151).

**Fix:** Use date inputs and strict ISO-date coercion for before/after; bounded nonnegative integer inputs/coercion for relative-day operators. Reject mismatched values with a visible validation message. Keep units synchronized when switching fields.

**Acceptance check:** Exercise all five date operators, switch between date and number fields, reload existing conditions, and submit malformed values. Valid dates filter correctly; invalid combinations never raise a server error.

### 05. [P2] Channel filter dialog retains stale state after frame navigation

**Evidence:** Traced.

The filter dialog sits outside the channels Turbo frame. Searching, changing the day window or removing a condition updates only the frame. Reopening the dialog shows old conditions and hidden search/range values; Apply can resurrect removed conditions or revert the current range/query.

**Code:** [web/app/views/channels/index.html.erb:73](/Volumes/STORAGE/code/nemo/web/app/views/channels/index.html.erb:73), [web/app/views/channels/index.html.erb:207](/Volumes/STORAGE/code/nemo/web/app/views/channels/index.html.erb:207), [web/app/views/channels/_filter_modal.html.erb:6](/Volumes/STORAGE/code/nemo/web/app/views/channels/_filter_modal.html.erb:6).

**Fix:** Render the dialog inside the replaced frame or update it explicitly alongside the frame. Preserve one authoritative representation of filter, search and range state.

**Acceptance check:** Apply a condition, remove its chip, change search/range, reopen and apply again. All controls and results must reflect the current URL without restoring earlier values.

### 06. [P2] Out-of-order search responses can select the wrong person or case

**Evidence:** Reproduced for member picker; related paths traced.

Issue a slow search for Alice, then a faster search for Bob. Alice’s response is allowed to overwrite Bob’s results. Clearing input or closing the picker also does not invalidate outstanding requests. The isolated test displays ALICE under a current bob query.

**Code:** [web/app/javascript/controllers/member_picker_controller.js:55](/Volumes/STORAGE/code/nemo/web/app/javascript/controllers/member_picker_controller.js:55), [web/app/javascript/controllers/mention_controller.js:41](/Volumes/STORAGE/code/nemo/web/app/javascript/controllers/mention_controller.js:41), [web/app/javascript/controllers/palette_controller.js:79](/Volumes/STORAGE/code/nemo/web/app/javascript/controllers/palette_controller.js:79).

**Fix:** Use AbortController and/or a monotonically increasing request token. Invalidate requests on input changes, clear, close and disconnect; handle rejected requests without reopening stale results. Apply the same contract to all search widgets.

**Acceptance check:** Delay responses deliberately and return them in reverse order. Only results for the latest input and scope may appear; no popover returns after it is closed.

### 07. [P2] Case chat does not auto-scroll to recent messages

**Evidence:** Reproduced selector mismatch.

The stick controller queries and listens for .chat-log, while the actual scroll container is .chatscroll. Its initial pin and follow-new-message behavior cannot find the element.

**Code:** [web/app/javascript/controllers/stick_controller.js:24](/Volumes/STORAGE/code/nemo/web/app/javascript/controllers/stick_controller.js:24), [web/app/views/fd/cases/_chat_log.html.erb:5](/Volumes/STORAGE/code/nemo/web/app/views/fd/cases/_chat_log.html.erb:5).

**Fix:** Use a Stimulus target shared by the template and controller instead of an obsolete CSS selector. Preserve the reader’s position when they have scrolled away from the bottom.

**Acceptance check:** Open a long conversation and receive a new message while at the bottom: stay at the bottom. Scroll upward and receive another: stay at the same reading position.

### 08. [P2] Live chat updates lose chronological order and date separators

**Evidence:** Traced.

Full rendering sorts entries and inserts day headings. Incremental rendering only emits message rows, and upsert appends unfamiliar IDs. A delayed older Slack message appears at the bottom; messages arriving on a new day appear below the previous day’s heading until a reload.

**Code:** [web/app/javascript/turbo_actions.js:103](/Volumes/STORAGE/code/nemo/web/app/javascript/turbo_actions.js:103), [web/app/views/fd/chat_logs/show.turbo_stream.erb:5](/Volumes/STORAGE/code/nemo/web/app/views/fd/chat_logs/show.turbo_stream.erb:5), [web/app/views/fd/cases/_chat_log.html.erb:13](/Volumes/STORAGE/code/nemo/web/app/views/fd/cases/_chat_log.html.erb:13).

**Fix:** Include a stable ordering key and insert entries in chronological order. Reconcile day separators and earlier-message counts after each update, or replace a bounded message-list fragment while preserving scroll.

**Acceptance check:** Deliver yesterday’s message after today’s, cross midnight, and transition an outbox item to a delivered message. Order and headings must match a clean full render with no duplicate entries.

### 09. [P2] Older case-chat and reporter messages cannot be read in the UI

**Evidence:** Traced.

After more than 50 internal or reporter messages, the controllers return only a tail. The earlier-message indicator is plain text, and the chat-log endpoint has no paging cursor or load-earlier path. Older content remains stored but cannot be inspected through this conversation view.

**Code:** [web/app/models/fd/case_chat.rb:6](/Volumes/STORAGE/code/nemo/web/app/models/fd/case_chat.rb:6), [web/app/models/fd/intake_message.rb:5](/Volumes/STORAGE/code/nemo/web/app/models/fd/intake_message.rb:5), [web/app/views/fd/cases/_chat_log.html.erb:7](/Volumes/STORAGE/code/nemo/web/app/views/fd/cases/_chat_log.html.erb:7), [web/app/controllers/fd/chat_logs_controller.rb:18](/Volumes/STORAGE/code/nemo/web/app/controllers/fd/chat_logs_controller.rb:18).

**Fix:** Add authorized cursor pagination for both message sources and a load-earlier control. Keep ordering stable and preserve scroll when prepending.

**Acceptance check:** Seed 120 messages per source, load all earlier pages and confirm every authorized message can be reached exactly once, including merged cases.

### 10. [P2] Chat reset responses never trigger the required full reload

**Evidence:** Reproduced in isolated JavaScript.

When a source count falls, the server returns HTTP 205 to request a reset. fetchChanges treats every successful status except 204 as a Turbo stream; 205 is successful and bodyless. It renders an empty stream instead of reloading, leaving obsolete rows/version state in the page.

**Code:** [web/app/controllers/fd/chat_logs_controller.rb:48](/Volumes/STORAGE/code/nemo/web/app/controllers/fd/chat_logs_controller.rb:48), [web/app/javascript/turbo_actions.js:21](/Volumes/STORAGE/code/nemo/web/app/javascript/turbo_actions.js:21).

**Fix:** Handle 205 explicitly with fullReload and clear pending state reliably. Define the reset response contract in one place.

**Acceptance check:** Return 205 after a message removal or family change. The list must reload once and match the server; the reproduction currently records zero reloads and one empty stream.

### 11. [P2] Several controls on merged-in records fail or silently discard the requested change

**Evidence:** Traced.

The parent case displays actions, notes and evidence from its whole family. Reverse posts to the parent but only updates actions whose case_id equals that parent; removing a child-case note similarly misses it. Selecting a flagged message from a child case when logging an action silently drops the citation because validation looks only at the parent’s threads.

**Code:** [web/app/controllers/fd/cases_controller.rb:27](/Volumes/STORAGE/code/nemo/web/app/controllers/fd/cases_controller.rb:27), [web/app/controllers/fd/reversals_controller.rb:25](/Volumes/STORAGE/code/nemo/web/app/controllers/fd/reversals_controller.rb:25), [web/app/controllers/fd/notes_controller.rb:75](/Volumes/STORAGE/code/nemo/web/app/controllers/fd/notes_controller.rb:75), [web/app/controllers/concerns/fd/logs_actions.rb:75](/Volumes/STORAGE/code/nemo/web/app/controllers/concerns/fd/logs_actions.rb:75).

**Fix:** Use a shared family-aware scope for record lookup and mutation, retaining author/capability checks. Reject invalid citations explicitly instead of silently removing them. Review standing-note subject validation against the displayed family as well.

**Acceptance check:** Merge B into A, then reverse B’s action, remove your B note, and cite B’s evidence from A. Each operation must succeed and audit the true originating record; unrelated records must remain inaccessible.

### 12. [P2] Merged-case chat does not receive live updates from child cases

**Evidence:** Traced.

The parent displays family-wide chat, but PostgreSQL notifications identify the changed record’s child case. The listener broadcasts only to that child’s stream, while the parent page subscribes to its own stream. New replies to a merged-in report are missed while the parent remains open; visibility catch-up or reload can later reveal them.

**Code:** [web/app/models/fd/chat_listener.rb:71](/Volumes/STORAGE/code/nemo/web/app/models/fd/chat_listener.rb:71), [web/app/models/fd/case_chat_broadcast.rb:19](/Volumes/STORAGE/code/nemo/web/app/models/fd/case_chat_broadcast.rb:19), [web/app/views/fd/cases/_chat.html.erb:41](/Volumes/STORAGE/code/nemo/web/app/views/fd/cases/_chat.html.erb:41).

**Fix:** Broadcast changes to all affected visible ancestors/root streams, or subscribe the parent to family streams. Reconcile subscriptions after merge/reopen.

**Acceptance check:** Keep A open after merging B into A and insert a chat/reporter message on B. A must update immediately without a tab switch or reload.

### 13. [P1] Deep merge chains hide retained case material

**Evidence:** Traced.

family_of traverses only five descendant levels; root_for also has a fixed ten-hop limit. Repeatedly merging the current root into another case can exceed these bounds. The newest root then omits older reports, notes, actions and evidence even though the records still exist.

**Code:** [web/app/models/fd/case.rb:193](/Volumes/STORAGE/code/nemo/web/app/models/fd/case.rb:193), [web/app/models/fd/case.rb:209](/Volumes/STORAGE/code/nemo/web/app/models/fd/case.rb:209).

**Fix:** Use a recursive, cycle-safe family query or flatten parent links transactionally during merge. Avoid silently returning a partial family when a limit is reached.

**Acceptance check:** Build a chain of at least 12 merges. Root lookup and family reads must include every case and record; introduce a cycle fixture and ensure traversal terminates with a clear error.

### 14. [P1] Concurrent opposite merges can create a cycle

**Evidence:** Traced concurrency interleaving; needs database regression test.

Two requests can resolve the roots before either writes: one merges A into B and the other B into A. Each then updates a different unresolved source row; neither locks/revalidates the destination. Both can commit, leaving A→B→A and no canonical open case.

**Code:** [web/app/controllers/fd/merges_controller.rb:45](/Volumes/STORAGE/code/nemo/web/app/controllers/fd/merges_controller.rb:45), [web/app/controllers/fd/merges_controller.rb:87](/Volumes/STORAGE/code/nemo/web/app/controllers/fd/merges_controller.rb:87).

**Fix:** Lock the participating roots in a deterministic order, recalculate roots inside the transaction, and reject self/descendant targets and conflicting changes. Add a database-level invariant where practical.

**Acceptance check:** Run simultaneous A→B and B→A transactions with a barrier before mutation. At most one succeeds; no cycle is persisted, and the loser receives a clear conflict response.

### 15. [P2] Merging into an already resolved case falsely promises an open keeper

**Evidence:** Traced.

Candidates can include resolved cases and chosen_target accepts any existing case. The merge closes the source but neither reopens nor rejects a resolved destination. The success message still says the keeper stays open, and the combined matter can disappear from the open queue.

**Code:** [web/app/controllers/fd/merges_controller.rb:72](/Volumes/STORAGE/code/nemo/web/app/controllers/fd/merges_controller.rb:72), [web/app/controllers/fd/merges_controller.rb:111](/Volumes/STORAGE/code/nemo/web/app/controllers/fd/merges_controller.rb:111), [web/app/models/fd/case.rb:159](/Volumes/STORAGE/code/nemo/web/app/models/fd/case.rb:159).

**Fix:** Define and enforce the destination rule. Prefer rejecting closed keepers unless the workflow explicitly reopens them; otherwise show accurate closed-destination consequences before merging and in the result.

**Acceptance check:** Select a resolved keeper through the picker and by direct request. The outcome must follow the chosen rule and must never claim the keeper is open when it is closed.

### 16. [P2] Resolution timeline attributes actions and notification status incorrectly

**Evidence:** Traced.

The timeline identifies the resolver as the first current assignee or the original opener rather than the actor recorded in the resolution audit. It also infers “the member was not told” from member_note being blank, even though member_note is separate from tell_reporter/member_message and delivery status.

**Code:** [web/app/models/fd/case_timeline.rb:135](/Volumes/STORAGE/code/nemo/web/app/models/fd/case_timeline.rb:135), [web/app/controllers/fd/resolutions_controller.rb:20](/Volumes/STORAGE/code/nemo/web/app/controllers/fd/resolutions_controller.rb:20).

**Fix:** Read the resolution actor from durable resolution metadata/audit. Derive notification wording from the corresponding delivery records, and distinguish queued, sent and failed outcomes.

**Acceptance check:** Have an unassigned third staff member resolve a case opened/assigned by others. Timeline attribution must name the resolver. Independently vary internal note text, notification choice and delivery result.

### 17. [P1] Reports are shown as told the outcome before notification succeeds

**Evidence:** Traced.

Checking tell_reporter sets each report’s closed_at before queueing. A report with no open conversation queues nothing; a later outbox failure also leaves closed_at set. CaseReport interprets that field as successfully told and shows a definitive sent date/person, hiding failed or impossible notification.

**Code:** [web/app/controllers/fd/resolutions_controller.rb:90](/Volumes/STORAGE/code/nemo/web/app/controllers/fd/resolutions_controller.rb:90), [web/app/controllers/fd/resolutions_controller.rb:99](/Volumes/STORAGE/code/nemo/web/app/controllers/fd/resolutions_controller.rb:99), [web/app/models/fd/case_report.rb:39](/Volumes/STORAGE/code/nemo/web/app/models/fd/case_report.rb:39).

**Fix:** Separate case/report closure from notification delivery. Record queued status at request time and set delivered metadata only after successful delivery. Surface missing conversation and failed delivery states with an actionable retry path.

**Acceptance check:** Resolve with a missing conversation, a permanent Slack failure and a successful delivery. Only the last scenario may show “told the outcome”; other states must stay visible and recoverable.

### 18. [P1] Incremental first-response analytics omit older backfills and late replies

**Evidence:** Traced.

The incremental candidate set is limited by first-post time relative to max(post_at) minus 24 hours. An older first post discovered during archive backfill is excluded even if the user has no result row. A reply arriving later than that window, or a correction to an older first post, also does not update the existing classification. Normal transforms do not full-refresh this model.

**Code:** [warehouse/models/staging/fct_first_response.sql:19](/Volumes/STORAGE/code/nemo/warehouse/models/staging/fct_first_response.sql:19), [pipeline/jobs/nightly_sync.py:155](/Volumes/STORAGE/code/nemo/pipeline/jobs/nightly_sync.py:155).

**Fix:** Build the incremental candidate set from changed messages/first-post identities and missing result keys, including late replies and deleted/replaced first posts. Use a bounded, explicit reconciliation/full-refresh path where a reliable change feed is unavailable.

**Acceptance check:** After an initial build, add a first post from last month and a reply to an existing old post, then run incrementally. Results must equal a clean full refresh.

### 19. [P1] Retention facts freeze before historical coverage corrections can land

**Evidence:** Traced.

Existing members whose first post is older than 91 days are excluded from incremental rebuilding. Delayed member-activity backfills, newly completed coverage, corrected first-post dates and cohort corrections therefore never repair their measured/retained flags through normal transforms.

**Code:** [warehouse/models/staging/fct_member_retention.sql:25](/Volumes/STORAGE/code/nemo/warehouse/models/staging/fct_member_retention.sql:25).

**Fix:** Recompute affected members when their activity, coverage, first-post or cohort inputs change. At minimum, continue rebuilding unsettled/uncovered records and provide periodic reconciliation for previously settled records.

**Acceptance check:** Create an old unmeasured member, add the missing historical coverage/activity, and run incrementally. Measured and retained flags must match a fresh full build.

### 20. [P1] Incomplete retention windows are presented as measured outcomes

**Evidence:** Traced.

day_30_covered and day_90_covered require only one fetched day in each window. If only day 23 is loaded and a member is inactive that day, the member enters the measured denominator as not retained even though the remaining days are absent or still in the future. The chart does not gate day-30 rates on complete window maturity.

**Code:** [warehouse/models/staging/fct_member_retention.sql:48](/Volumes/STORAGE/code/nemo/warehouse/models/staging/fct_member_retention.sql:48), [warehouse/models/marts/mart_cohort_retention.sql:31](/Volumes/STORAGE/code/nemo/warehouse/models/marts/mart_cohort_retention.sql:31), [web/app/models/analytics/mart_cohort_retention.rb:6](/Volumes/STORAGE/code/nemo/web/app/models/analytics/mart_cohort_retention.rb:6).

**Fix:** Define coverage from the full expected set of daily slices and elapsed window boundaries. Mark incomplete outcomes unknown, or expose an explicitly partial metric with its own denominator. Use the daily coverage ledger rather than assuming activity-row presence is complete observation.

**Acceptance check:** Load one day of a window, then all but one, then all days. The first two must not count as a complete negative observation; only mature fully observed windows enter the definitive rate.

### 21. [P2] Retention uses eight days while the interface promises seven

**Evidence:** Reproduced interval count; SQL/view traced.

Inclusive ranges day 23–30 and day 83–90 contain eight dates. The card explicitly describes seven days ending on days 30 and 90. Members active only on days 23 or 83 are therefore included beyond the displayed definition.

**Code:** [warehouse/models/staging/fct_member_retention.sql:78](/Volumes/STORAGE/code/nemo/warehouse/models/staging/fct_member_retention.sql:78), [web/app/views/journey/_cohort_retention.html.erb:6](/Volumes/STORAGE/code/nemo/web/app/views/journey/_cohort_retention.html.erb:6).

**Fix:** Agree on the definition and use one shared metric contract. For the current seven-day label, use days 24–30 and 84–90 consistently in coverage, outcomes and tests.

**Acceptance check:** Boundary fixtures active only on days 23, 24, 83 and 84 must produce the documented results. The coverage test must count the same seven dates.

### 22. [P2] First-response metadata can describe the wrong winning response

**Evidence:** Traced.

If a channel mention arrives at 10:05 and a thread reply at 10:20, responded_at and latency use 10:05, but detection_method/confidence select the presence of any thread reply and report thread_reply/high. The provenance does not describe the response used by the metric.

**Code:** [warehouse/models/staging/fct_first_response.sql:65](/Volumes/STORAGE/code/nemo/warehouse/models/staging/fct_first_response.sql:65), [warehouse/models/staging/fct_first_response.sql:67](/Volumes/STORAGE/code/nemo/warehouse/models/staging/fct_first_response.sql:67).

**Fix:** Choose the winning response once, with an explicit tie rule, and derive time, method and confidence from that same candidate.

**Acceptance check:** Cover mention-first, thread-first, tied, bot-only and no-response cases. Method/confidence must always identify the timestamp used for latency.

### 23. [P1] Temporary event-projection lock failures are marked permanently complete

**Evidence:** Reproduced using existing test doubles and real fault classification.

per_entity swallows a retryable lock/deadlock fault, rolls back and continues. event_projector.run still appends that event ID to done and stamps projected_at. Since pending selects only projected_at IS NULL, the event is never automatically retried. The reproduction raises LockNotAvailable for E0 and observes E0 marked projected.

**Code:** [pipeline/ingest/event_projector.py:62](/Volumes/STORAGE/code/nemo/pipeline/ingest/event_projector.py:62), [pipeline/lib/task.py:19](/Volumes/STORAGE/code/nemo/pipeline/lib/task.py:19), [db/faults.yml:26](/Volumes/STORAGE/code/nemo/db/faults.yml:26).

**Fix:** Return an explicit outcome from per_entity/project and mark only successful or intentionally quarantined permanent failures complete. Keep transient failures pending with bounded backoff and observable retry state.

**Acceptance check:** Inject LockNotAvailable and DeadlockDetected on one event. Other events advance; the failed event remains pending and projects on the next successful pass. Preserve poison-event quarantine behavior.

### 24. [P1] New edit events cannot update an API-settled archived message

**Evidence:** Traced.

History/reply API rows are settled=true, while event projections use settled=false. The upsert’s blanket condition rejects every later event update to a settled row, including a legitimate newer edit. The envelope/observation may be recorded and the delivery marked projected, but current metadata such as mentions, text length and edited_at stays stale until another API fetch happens, if it ever does.

**Code:** [pipeline/lib/archive.py:59](/Volumes/STORAGE/code/nemo/pipeline/lib/archive.py:59), [pipeline/ingest/event_projector.py:37](/Volumes/STORAGE/code/nemo/pipeline/ingest/event_projector.py:37).

**Fix:** Reconcile by revision/event time and field provenance. Permit a newer authoritative edit to update a settled message while rejecting older/stale events; alternatively enqueue a guaranteed targeted refetch before acknowledging projection.

**Acceptance check:** Archive an API message, project a newer edit, then an older duplicate event. Current metadata must reflect the newer edit and must not regress.

### 25. [P2] Proxy budget mode from .env is ignored

**Evidence:** Reproduced with a mocked dotenv loader.

proxy.app imports budget before loading proxy/.env. budget.MODE is read at import time, so PROXY_BUDGET=observe/off from that file arrives too late and the default on mode remains active. Exporting the variable in the process environment avoids the bug but the app’s own dotenv path does not.

**Code:** [proxy/app.py:16](/Volumes/STORAGE/code/nemo/proxy/app.py:16), [proxy/app.py:26](/Volumes/STORAGE/code/nemo/proxy/app.py:26), [proxy/budget.py:8](/Volumes/STORAGE/code/nemo/proxy/budget.py:8).

**Fix:** Load configuration before constructing budget state, or initialize/read mode explicitly during app startup. Make the effective mode visible and validated.

**Acceptance check:** Start with the variable absent from the process environment and each supported value supplied by dotenv. Effective behavior and /budget must match the file.

### 26. [P2] Custom ranges crash for newly created channels with no available analytics yet

**Evidence:** Reproduced Ruby clamp failure; request path traced.

For a channel created today when analytics ends two days ago, floor exceeds last_available. Any custom start/end causes Date#clamp(floor, last_available) to raise ArgumentError. The non-custom path can also request an all-time interval whose start is after its end.

**Code:** [web/app/controllers/channels_controller.rb:88](/Volumes/STORAGE/code/nemo/web/app/controllers/channels_controller.rb:88), [web/app/controllers/channels_controller.rb:91](/Volumes/STORAGE/code/nemo/web/app/controllers/channels_controller.rb:91).

**Fix:** Detect the no-overlapping-data case before clamping or calling the proxy. Render a not-yet-available state and disable impossible ranges; normalize all intervals centrally.

**Acceptance check:** Open a channel created after the coverage end with default, preset and custom ranges. All paths must render gracefully and send no inverted interval upstream.

### 27. [P2] Treemap calls existing low-volume channels “new”

**Evidence:** Reproduced generated SVG label.

A channel with 250 messages in the prior period and 300 now is marked thin because the prior total is below 500. The treemap displays “new” for every thin or missing-percentage tile, although the channel plainly existed and had activity before.

**Code:** [web/app/javascript/charts/treemap_controller.js:156](/Volumes/STORAGE/code/nemo/web/app/javascript/charts/treemap_controller.js:156), [warehouse/models/marts/mart_channel_momentum.sql:51](/Volumes/STORAGE/code/nemo/warehouse/models/marts/mart_channel_momentum.sql:51).

**Fix:** Use “n/a” or “small sample” for insufficient comparison data. Reserve “new” for an explicit channel-creation or zero-prior condition whose meaning is documented.

**Acceptance check:** Test a preexisting low-volume channel, an unavailable prior period, a newly created channel and a sufficiently measured channel. Labels must describe the actual reason percentage change is unavailable.

### 28. [P1] Warehouse quality gates run after live marts have already been published

**Evidence:** Traced.

run_dbt first runs dbt against the live model schemas and then executes dbt tests. A failing gate raises “refusing to publish”, but the table replacements have already committed; there is no staging schema, promotion step or rollback of the previous build. Readers can receive data that the gate subsequently rejects, and failed runs can leave a mix of old and new models.

**Code:** [pipeline/jobs/nightly_sync.py:155](/Volumes/STORAGE/code/nemo/pipeline/jobs/nightly_sync.py:155), [pipeline/jobs/nightly_sync.py:167](/Volumes/STORAGE/code/nemo/pipeline/jobs/nightly_sync.py:167), [warehouse/dbt_project.yml:23](/Volumes/STORAGE/code/nemo/warehouse/dbt_project.yml:23).

**Fix:** Build and test an isolated candidate schema/version, then atomically promote the validated set or switch a stable reader layer. Preserve the last good release on any build/test failure and report which version is being served.

**Acceptance check:** Force a gate failure and a mid-build failure. Dashboard reader queries must continue returning the prior validated version. A successful build must promote one coherent version only after checks pass.

## Plan to fix all findings

Implement this as focused changes with regression checks alongside each fix. Keep Slack calls stubbed in tests and use a seeded local database for case workflows.

| Order | Work | Findings | Completion criterion |
| --- | --- | --- | --- |
| 0 | Establish a reproducible test environment | Supports all | Use the repository’s Ruby version and lockfiles, provision isolated PostgreSQL, seed tiny data and run the existing Rails/Python/dbt checks. Add a browser test entry point; record baseline screenshots. |
| 1 | Protect access and prevent unintended sends | 01–03 | Restricted channel data is absent from responses. Mention/IME input cannot send prematurely in any recipient mode. |
| 2 | Make case mutations and outcomes reliable | 11, 13–17 | Family-wide controls operate on the intended records, merges cannot cycle or hide older material, destination state is explicit, and audit/delivery wording reflects actual actors and delivery results. |
| 3 | Preserve ingestion correctness and validated publication | 23–25, 28 | Transient event failures retry, newer edits reconcile correctly, dotenv mode works, and failed warehouse builds cannot replace the last validated reader version. |
| 4 | Repair analytics and reconcile affected history | 18–22, 26–27 | Incremental results equal full recomputation on late-data/correction fixtures; retention uses complete, mature windows with consistent bounds; empty date intervals and treemap labels are truthful. |
| 5 | Repair filtering, searches and conversation presentation | 04–10, 12 | Filter/URL/dialog state agrees; searches reject stale responses; scrolling, pagination, ordering, date headings, resets and merged-case live updates work together. |
| 6 | Complete end-to-end and visual regression audit | All | Run the role/state/device matrix below, resolve any newly discovered defects and rerun only affected checks. |

Steps 2 and 3 can be separate changes after the baseline is established. Finish validated publication before rebuilding corrected historical metrics. Each row above covers every enumerated ID; the detailed acceptance check under each finding is its definition of done.

### Data repair and rollout

1. Before changing historical calculations, record the current served build/version and compare a representative set of cohort/channel totals against an isolated recomputation.
2. After fixing event acknowledgement, identify transiently rejected deliveries using dead letters and event IDs. Requeue only the affected deliveries; do not replay report notifications or unrelated external actions.
3. Reconcile API-settled messages with newer stored edit envelopes, or schedule targeted API refetches where the envelope lacks sufficient data. Verify revision ordering before replay.
4. Repair any merge cycles/deep chains through an audited, reviewed migration that preserves records and original case IDs. Then compare family counts for reports/actions/notes/evidence before and after.
5. Rebuild first-response and retention models plus dependent marts in a candidate schema. Compare incremental and full builds, verify coverage/metric definitions, run gate tests, and only then promote.
6. Existing reports marked closed do not prove a notification was sent. Backfill delivery status from successful outbox records where evidence exists; label ambiguous history unknown rather than inventing a delivered timestamp.

### Required final verification matrix

- **Roles:** ordinary signed-in account, channel-granted account, operational staff, case staff, manager; repeat relevant paths with analytics/fire-engine feature flags off.
- **Case states:** open, resolved, merged, more than five merge levels, missing subject, multiple reporters, closed conversation, pending/failed/delivered reply, more than 50 messages, foreign/author-owned notes, concurrent opposite merges.
- **Data states:** empty data, fresh channel beyond coverage, missing days, incomplete windows, zero activity, low comparison sample, late first post/reply, corrected/deleted message, historical coverage repair and deliberately failed warehouse gates.
- **UI:** desktop and narrow screens at 320, 375, 768, 1024 and 1440 pixels; light/dark themes; keyboard-only navigation; IME input; reduced motion; long names and text; delayed/out-of-order responses; tab visibility changes and reconnects. Capture representative screenshots and verify overflow, clipping, focus, dialogs, chart labels and message ordering.
- **Automation:** preserve the existing suite; add targeted Rails/database tests for access and family mutations, JavaScript/browser tests for interaction contracts, dbt fixtures that compare incremental versus full builds, and proxy startup configuration tests. Include bot/proxy and browser coverage in CI, which currently concentrates on pipeline, warehouse and Rails checks.

## Reproduction artifacts

- [JavaScript reproductions](/Volumes/STORAGE/code/nemo/docs/audit-2026-09-12/reproduce.cjs): executes the current controller/response-handler methods with small test doubles. Covers findings 02, 03, 04, 06, 07, 10 and 27.
- [Python reproductions](/Volumes/STORAGE/code/nemo/docs/audit-2026-09-12/reproduce.py): uses existing event-projector test doubles and real fault classification, plus a mocked dotenv loader. Covers findings 23 and 25; requires the pipeline’s development dependencies and the proxy’s FastAPI dependencies.

Run these from the repository root using Node and the configured Python environment:

```text
node docs/audit-2026-09-12/reproduce.cjs
python docs/audit-2026-09-12/reproduce.py
```

Current JavaScript output:

```text
Mention Enter submissions: 1 (expected 0)
IME Enter submissions: 1 (expected 0)
Absolute date filter input: number (expected date)
Stick controller finds actual markup: false (expected true)
Latest bob search displays: ALICE (expected BOB)
Existing low-volume treemap says new: true (expected false)
205 reset: reloads / empty streams: 0 1 (expected 1 / 0)
```

Current Python output includes:

```text
Transiently failed event E0 marked projected: True (expected False)
dotenv configured mode / actual budget mode: observe on (expected observe / observe)
```
