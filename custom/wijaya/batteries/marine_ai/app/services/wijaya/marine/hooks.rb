module Wijaya::Marine::Hooks
  module_function

  # Consolidated claim used by MessageTemplates::HookExecutionService. Returns
  # true when Marine is handling this conversation — in which case the native
  # welcome/OOO/email-collect templates must be suppressed — and, when the
  # triggering message is a genuine inbound turn, schedules the Marine response.
  # Returns false (native templates run) for non-Marine inboxes.
  #
  # should_process_marine_response? already implies marine_handling_conversation?
  # (it is that predicate plus message.incoming?), so scheduling only fires for
  # inbound turns while suppression covers every message Marine is handling —
  # byte-for-byte with the previous four inline guards.
  def claim_message_templates!(conversation:, inbox:, message:)
    return false unless marine_handling_conversation?(conversation: conversation, inbox: inbox)

    after_message_template_trigger(conversation: conversation, inbox: inbox, message: message)
    true
  end

  def after_message_template_trigger(conversation:, inbox:, message:)
    reset_expired_handoff(conversation, inbox, message)
    return unless should_process_marine_response?(conversation, inbox, message)

    schedule_marine_response(conversation, message)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: conversation.account).capture_exception
  end

  # A handoff keeps Marine silent only for the applicable ACTIVE channel messaging window.
  # When this new inbound turn opens a FRESH window (the prior window lapsed — see
  # Marine::Circuit::HandoffWindow), clear the terminal handoff marker so the turn can start a
  # new Marine interaction. This is purely inbound-driven: window expiry alone never runs it
  # (no message => no hook => no reset => no output), satisfying "expiry emits nothing".
  #
  # Human takeover has strict precedence over window expiry: if a human agent has taken over
  # (a public outgoing User reply OR an exact external_echo native-app reply — the SAME canonical
  # semantics Marine::Conversation::Eligibility uses), the marker is left ACTIVE and never reset,
  # so a handed-over conversation is never re-engaged and no ResponseBuilderJob is enqueued for it,
  # regardless of how many inbound turns arrive after the window lapses. Checked BEFORE the window
  # computation so takeover blocks reset independently of any channel-window policy. Passive
  # assignment/team routing is NOT a takeover (Eligibility#human_takeover? reads only public human
  # replies), so it never permanently blocks post-window Marine re-entry.
  def reset_expired_handoff(conversation, inbox, message)
    return unless message.incoming?
    return unless inbox.respond_to?(:marine_assistant) && inbox.marine_assistant.present?
    return unless marine_handoff_active?(conversation)
    return if ::Marine::Conversation::Eligibility.new(conversation: conversation).human_takeover?
    return unless ::Marine::Circuit::HandoffWindow.new(conversation: conversation, message: message).expired?

    ::Marine::Circuit::HandoffStateStore.new(conversation: conversation).reset!
  end

  # Linked Marine assistant id for an inbox, or nil when Marine is not linked.
  # Used by the core inbox serializer via the fail-open dispatcher.
  def inbox_marine_assistant_id(inbox:)
    return nil unless inbox.respond_to?(:marine_assistant)

    inbox.marine_assistant&.id
  end

  def after_conversation_resolved(conversation)
    inbox = conversation&.inbox
    return unless marine_memory_enabled?(conversation, inbox)

    ::Marine::Memory::GenerateContactNotesJob.perform_later(conversation)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: conversation&.account).capture_exception
  end

  def marine_memory_enabled?(conversation, inbox)
    return false if conversation.blank? || inbox.blank?

    assistant = inbox.respond_to?(:marine_assistant) ? inbox.marine_assistant : nil
    assistant.present? && assistant.respond_to?(:feature_memory) && assistant.feature_memory.present?
  end

  def marine_handling_conversation?(conversation:, inbox:)
    return false unless inbox.respond_to?(:marine_assistant) && inbox.marine_assistant.present?
    return false if conversation.resolved? || conversation.snoozed?

    # Marine handles the conversation until a human agent sends a reply.
    # We check for sender_type 'User' (human) — Marine's own replies use
    # sender_type 'Marine::Assistant' and must not block subsequent turns.
    conversation.messages.outgoing.where(private: false).where(sender_type: 'User').empty?
  end

  def should_process_marine_response?(conversation, inbox, message)
    return false unless message.incoming?
    return false unless inbox.respond_to?(:marine_assistant) && inbox.marine_assistant.present?
    return false if conversation.resolved? || conversation.snoozed?
    # While a circuit handoff is active Marine stays silent — never enqueue another response.
    # The marker is cleared upstream (reset_expired_handoff) once a new inbound turn opens a
    # fresh channel messaging window, so by the time we get here an active marker means the
    # applicable window has NOT lapsed yet.
    return false if marine_handoff_active?(conversation)

    # Marine handles until a human agent replies.  WhatsApp conversations
    # are created as 'open' (not 'pending' like web widget), so we check
    # for human (User) outgoing messages instead of the conversation status.
    conversation.messages.outgoing.where(private: false).where(sender_type: 'User').empty?
  end

  # Suppression (marine_handling_conversation?) deliberately does NOT consult this: while
  # a handoff is active Marine must keep claiming the native welcome/OOO/email-collect
  # templates so they stay suppressed. Only response scheduling is gated on it.
  def marine_handoff_active?(conversation)
    ::Marine::Circuit::HandoffStateStore.new(conversation: conversation).active?
  end

  # Phase 5 — bind the scheduled Marine response to the EXACT incoming message.id
  # that triggered it. The job's third argument is optional (defaults to nil) so
  # already-enqueued 2-arg jobs keep their legacy behavior; a present id activates
  # the trigger-bound product/RAG flow with per-message idempotency.
  def schedule_marine_response(conversation, message)
    job_args = [conversation, conversation.inbox.marine_assistant, message.id]
    scheduled =
      if message.attachments.blank?
        ::Marine::Conversation::ResponseBuilderJob.perform_later(*job_args)
      else
        ::Marine::Conversation::ResponseBuilderJob.set(wait: 2.seconds).perform_later(*job_args)
      end

    # Phase 2 / Stage 4 — DEFAULT-OFF, asynchronous, fire-and-forget shadow of the isolated
    # Marine Decision Runner. Fired ONLY when the primary enqueue above genuinely succeeded
    # (see primary_enqueue_succeeded?), and enqueues nothing (no Redis, no job) unless
    # MARINE_DECISION_SHADOW_ENABLED is exactly on. The enqueuer swallows every config/Redis/job
    # error and returns a boolean we discard, so the shadow never influences this method's return
    # value (`scheduled`) or the caller's rescue/error behavior.
    if primary_enqueue_succeeded?(scheduled)
      ::Marine::Decision::ShadowEnqueuer.enqueue(conversation: conversation, message: message)
      # Fase 3A-2 — DEFAULT-OFF, asynchronous, fire-and-forget PRODUCT-authority shadow. Independent
      # of the scenario-level decision shadow above (separate flag/allowlist/Redis namespace/job).
      # Enqueues nothing unless MARINE_PRODUCT_AUTHORITY_SHADOW_ENABLED is exactly on for THIS
      # assistant; it re-runs the legacy IntentExtractor vs the Fase 3A-1 adapter outcome in a job
      # and records only aggregate metrics. The enqueuer swallows every config/Redis/job error and
      # returns a boolean we discard, so it never influences `scheduled` or the caller's behavior.
      # The ONLY provider/legacy-extractor work (no NEW provider call is added here) happens later
      # inside Marine::ProductAuthority::ShadowJob, AFTER a fresh allowlist/rollback re-check on the
      # loaded assistant id, where every timeout/error is swallowed and no metric is fabricated — so
      # it can never add latency to, or alter the result of, the primary reply path.
      ::Marine::ProductAuthority::ShadowEnqueuer.enqueue(conversation: conversation, message: message)
    end
    scheduled
  end

  # True only when the primary ResponseBuilderJob enqueue proved successful, so the shadow is
  # never fired for a response that did not actually enqueue. ActiveJob's perform_later returns
  # false when a before_enqueue callback halts the chain, and returns the job (responding to
  # #successfully_enqueued? / carrying #enqueue_error) otherwise. A legacy/test truthy object
  # exposing neither API counts as success for backward compatibility. Any error while checking
  # fails closed to no shadow and never replaces or alters the primary return object.
  def primary_enqueue_succeeded?(scheduled)
    return false unless scheduled
    return scheduled.successfully_enqueued? if scheduled.respond_to?(:successfully_enqueued?)
    return false if scheduled.respond_to?(:enqueue_error) && !scheduled.enqueue_error.nil?

    true
  rescue StandardError
    false
  end
end
