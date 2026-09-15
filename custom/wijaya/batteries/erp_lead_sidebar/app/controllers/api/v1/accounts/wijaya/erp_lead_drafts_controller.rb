# WIJAYA_CUSTOM_START erp_lead_sidebar
class Api::V1::Accounts::Wijaya::ErpLeadDraftsController < Api::V1::Accounts::BaseController
  before_action :set_conversation, except: [:options]
  before_action :set_draft, except: [:options]

  def show
    refresh = refresh_from_erp
    render json: serialize(@draft)
      .merge(options: option_values)
      .merge(owner_directory)
      .merge(refresh)
      .merge(configured: erp_configured?)
  end

  # Populates the sidebar select dropdowns from their ERPNext source DocTypes.
  def options
    render json: { options: ::Wijaya::Batteries::ErpLeadSidebar::OptionsService.new(Current.account).fetch_all }
  rescue ::Wijaya::Batteries::ErpLeadSidebar::SyncError
    # Never surface the raw ERPNext response/exception to the agent.
    render json: { error: 'ERP options are currently unavailable.', options: {} }, status: :bad_gateway
  end

  def update
    # ERP unconfigured: never persist a draft. Autosave from the sidebar must not
    # create rows until the ERP connection is configured.
    return render json: serialize(@draft).merge(configured: false) unless erp_configured?

    @draft.update!(fields: permitted_fields, sync_status: 'draft', last_error: nil)
    render json: serialize(@draft).merge(configured: true)
  end

  def sync # rubocop:disable Metrics/AbcSize
    # ERP unconfigured: fail closed before any persistence or outbound request.
    return render json: serialize(@draft).merge(configured: false) unless erp_configured?

    @draft.update!(fields: permitted_fields) if params[:fields].present?
    result = ::Wijaya::Batteries::ErpLeadSidebar::SyncService.new(@draft).perform
    # Carry a confirmed-but-pending Lead Owner to ERP now the Lead is linked: the owner has its
    # own validated OwnerSyncJob and enqueues are idempotent (a still-pending marker defeats a
    # false no-op), so this is safe even if the link seam already fired. Never blocks the
    # successful full-field sync — enqueue_owner_sync is fail-open.
    enqueue_owner_sync if ActiveModel::Type::Boolean.new.cast(@draft.fields['lead_owner_sync_pending'])
    success_message = @draft.erp_lead_id.present? ? "ERP Lead #{@draft.erp_lead_id} synced successfully." : 'ERP Lead synced successfully.'
    render json: serialize(@draft).merge(payload: result[:payload], conflict: false, message: success_message)
  rescue ::Wijaya::Batteries::ErpLeadSidebar::ValidationError => e
    # Field validation messages are locally generated and safe to surface.
    @draft.update!(sync_status: 'failed', last_error: e.message)
    render json: serialize(@draft).merge(error: e.message), status: :unprocessable_entity
  rescue ::Wijaya::Batteries::ErpLeadSidebar::SyncError
    # Never surface the raw ERPNext response/exception to the agent or store it.
    message = 'ERP sync failed. Please verify the ERP connection and try again.'
    @draft.update!(sync_status: 'failed', last_error: message)
    render json: serialize(@draft).merge(error: message), status: :unprocessable_entity
  end

  # Dedicated, validated Lead Owner path. Never a generic allowlist entry: the owner
  # is set here through the same live ERP User validator the owner-sync battery uses,
  # so an arbitrary/stale/disabled/Guest value can never reach ERP.
  #   * reset=true            -> only after synchronously resolving and validating the
  #                              CURRENT committed assignee as a selectable ERP User,
  #                              clear the sticky manual override and mark the owner sync
  #                              pending so it resumes following the assignee. If there is
  #                              no assignee, the assignee is not a valid ERP User, or the
  #                              directory is unavailable, fail closed and leave the manual
  #                              override + owner unchanged.
  #   * retry=true            -> explicit "Retry Lead Owner sync". Re-derive and revalidate the
  #                              CURRENT desired owner (the sticky manual owner, or the committed
  #                              assignee in automatic mode), keep the pending marker and re-enqueue
  #                              exactly that current mode/target. Fails closed on an invalid owner
  #                              or a directory outage and never touches unrelated Lead fields.
  #   * owner present         -> validate, then persist a sticky manual override AND a
  #                              pending marker; the owner-only ERP write is done by
  #                              OwnerSyncJob (linked drafts) or applied at link time
  #                              (unlinked drafts). Local storage is never proof of sync.
  def owner
    return render json: serialize(@draft).merge(configured: false) unless erp_configured?

    if reset_owner?
      apply_owner_reset
    elsif retry_owner?
      apply_owner_retry
    else
      apply_owner_manual
    end
  rescue ::Wijaya::Batteries::ErpLeadSidebar::SyncError
    # Fail closed: a directory outage is never treated as a valid owner.
    render json: serialize(@draft).merge(error: 'ERP user directory is unavailable; the Lead Owner was not changed.'),
           status: :bad_gateway
  end

  private

  def reset_owner?
    ActiveModel::Type::Boolean.new.cast(params[:reset])
  end

  def retry_owner?
    ActiveModel::Type::Boolean.new.cast(params[:retry])
  end

  def apply_owner_manual
    owner = params[:owner].to_s.strip
    return render_owner_error('Select a valid ERP user for the Lead Owner.') if owner.blank?
    unless ::Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory.valid?(Current.account, owner)
      return render_owner_error('That user is not a selectable ERP user. Pick one from the list.')
    end

    # Store the manual owner AND a pending marker: the owner has not reached ERP yet, so
    # the marker (not the stored value) is the proof-of-sync signal OwnerSyncService reads.
    @draft.update!(fields: @draft.fields.merge('lead_owner' => owner, 'lead_owner_override' => true, 'lead_owner_sync_pending' => true))
    return render_owner_enqueue_failure unless enqueue_owner_sync

    # Truthful: the choice is saved and queued, not yet confirmed in ERP.
    render json: serialize(@draft).merge(configured: true, message: 'Lead Owner saved; syncing to ERP. It will stay until reset.')
  end

  # Explicit "Retry Lead Owner sync": re-derive and revalidate the CURRENT desired owner, keep
  # the pending marker set and re-enqueue exactly that current mode/target. Only meaningful once
  # the Lead is linked — an unlinked draft's pending owner is applied automatically when the Lead
  # first links, so there is no retry to perform yet. Never alters unrelated Lead fields.
  def apply_owner_retry
    return render_owner_error('The Lead is not created yet; the Lead Owner will sync once it exists.') if @draft.erp_lead_id.blank?

    owner = retry_target_owner
    return render_owner_error('No valid ERP user is available for the Lead Owner yet. Pick one from the list.') if owner.blank?

    @draft.update!(fields: @draft.fields.merge('lead_owner_sync_pending' => true))
    return render_owner_enqueue_failure unless enqueue_owner_sync

    render json: serialize(@draft).merge(configured: true, message: 'Retrying the Lead Owner sync to ERP.')
  end

  # The owner to resend on retry: the sticky manual owner if an override is active, otherwise the
  # current committed assignee. Both are exact-revalidated against the live ERP User directory
  # (raising SyncError on an outage -> handled by #owner's fail-closed 502 rescue). Nil when the
  # desired owner is blank or not a selectable ERP User, so retry declines rather than queuing a
  # doomed job.
  def retry_target_owner
    return current_assignee_owner unless ActiveModel::Type::Boolean.new.cast(@draft.fields['lead_owner_override'])

    owner = @draft.fields['lead_owner'].to_s.strip
    return nil if owner.blank?
    return nil unless ::Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory.valid?(Current.account, owner)

    owner
  end

  def apply_owner_reset
    # Prove a valid assignee owner exists BEFORE clearing the override: never drop the
    # sticky manual owner on a false success while ERP still holds it. Raises SyncError on
    # a directory outage, handled by #owner's rescue (fail closed 502, override preserved).
    owner = current_assignee_owner
    return render_owner_error('Assign an agent with a valid ERP user before the Lead Owner can follow the assignee.') if owner.blank?

    @draft.update!(fields: @draft.fields.except('lead_owner', 'lead_owner_override').merge('lead_owner_sync_pending' => true))
    return render_owner_enqueue_failure unless enqueue_owner_sync

    render json: serialize(@draft).merge(configured: true, message: 'Lead Owner will follow the assigned agent; syncing to ERP.')
  end

  # The current committed assignee email, validated as a selectable enabled non-Guest ERP
  # User, or nil when there is no assignee / it is not a valid ERP User. Propagates
  # SyncError on a directory outage so the caller fails closed.
  def current_assignee_owner
    email = @conversation.assignee&.email.to_s.strip
    return nil if email.blank?
    return nil unless ::Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory.valid?(Current.account, email)

    email
  end

  def render_owner_error(message)
    render json: serialize(@draft).merge(error: message), status: :unprocessable_entity
  end

  # Explicit manual/reset endpoints must not report success when the ERP sync could not be
  # queued: the pending marker is already persisted (retryable), so surface a sanitized
  # failure instead of a false completed claim. Never expose the raw queue error.
  def render_owner_enqueue_failure
    render json: serialize(@draft).merge(
      error: 'The Lead Owner change was saved but could not be queued for ERP sync. Please try again.'
    ), status: :service_unavailable
  end

  # Post-link owner reconciliation is owned by the sibling battery. An unlinked draft has
  # nothing to enqueue yet — the pending override is applied when the Lead first links, so
  # that is a legitimate pending state, not a failure (returns true). A real enqueue error
  # returns false so the manual/reset endpoints can surface a truthful failure; the native
  # after-commit assignment seam stays fail-open separately.
  def enqueue_owner_sync
    return true if @draft.erp_lead_id.blank?

    ::Wijaya::Batteries::ErpLeadOwnerSync::OwnerSyncJob.perform_later(@conversation.id, @conversation.assignee_id)
    true
  rescue StandardError => e
    Rails.logger.error("Wijaya ERP Lead owner sync enqueue failed: #{e.class}")
    false
  end

  # Selectable ERP Users [{ value, label }] for the manual Lead Owner picker, plus
  # whether the directory was reachable. A directory outage degrades to an empty,
  # optional list (the picker is unavailable) and never breaks the sidebar open.
  def owner_directory
    return { owner_options: [], owner_options_available: false } unless erp_configured?

    options = ::Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory.fetch_options(Current.account)
    { owner_options: options, owner_options_available: true }
  rescue ::Wijaya::Batteries::ErpLeadSidebar::SyncError => e
    Rails.logger.warn("Wijaya ERP Lead owner directory unavailable for draft show: #{e.class}")
    { owner_options: [], owner_options_available: false }
  end

  # Reconcile the linked ERP Lead into the draft before serialize so the sidebar
  # opens on current ERP data (or a conflict/warning when local edits are unsynced
  # or ERP is unreachable). Never breaks show if refresh fails.
  def refresh_from_erp
    ::Wijaya::Batteries::ErpLeadSidebar::RefreshService.new(@draft).perform
  rescue StandardError => e
    Rails.logger.warn("Wijaya ERP Lead refresh unavailable for draft show: #{e.class}")
    {}
  end

  def option_values
    ::Wijaya::Batteries::ErpLeadSidebar::OptionsService.new(Current.account).fetch_all
  rescue ::Wijaya::Batteries::ErpLeadSidebar::SyncError => e
    Rails.logger.warn("Wijaya ERP Lead options unavailable for draft show: #{e.class}")
    {}
  end

  def set_conversation
    # Conversations are addressed by display_id everywhere in the dashboard
    # (the conversation JSON exposes display_id as `id`), so resolve by that.
    @conversation = Current.account.conversations.find_by!(display_id: params[:id])
  end

  def set_draft
    attrs = { account: Current.account, conversation: @conversation }
    # Opening the sidebar must not create a draft row while ERP is unconfigured.
    # Persist on open only when configured; otherwise return the existing draft or
    # a transient unsaved record so the panel can still render client autofill.
    @draft =
      if erp_configured?
        ::Wijaya::ErpLeadDraft.find_or_create_by!(**attrs) do |draft|
          draft.fields = {}
          draft.sync_status = 'draft'
        end
      else
        ::Wijaya::ErpLeadDraft.find_or_initialize_by(**attrs) do |draft|
          draft.fields = {}
          draft.sync_status = 'draft'
        end
      end
  end

  def erp_configured?
    ::Wijaya::Batteries::ErpLeadSidebar::Config.erp_configured?(Current.account)
  end

  # The full-form autosave replaces the whole fields blob, so lead_owner is never an
  # accepted browser input here (it has its own validated #owner path). Server-managed
  # owner keys are re-merged from the persisted draft so a routine field autosave never
  # drops the current owner or the sticky manual override.
  OWNER_MANAGED_KEYS = %w[lead_owner lead_owner_override lead_owner_sync_pending].freeze

  def permitted_fields
    raw = params[:fields].presence || {}
    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    allowed = ::Wijaya::Batteries::ErpLeadSidebar::PayloadBuilder::DIRECT_FIELDS +
              ::Wijaya::Batteries::ErpLeadSidebar::Config::MARKET_CUSTOMER_FIELDS +
              ::Wijaya::Batteries::ErpLeadSidebar::Config::JENIS_PAKAIAN_FIELDS
    raw.slice(*allowed).merge(@draft.fields.slice(*OWNER_MANAGED_KEYS))
  end

  def serialize(draft)
    {
      id: draft.id,
      conversation_id: draft.conversation_id,
      fields: draft.fields,
      sync_status: draft.sync_status,
      erp_lead_id: draft.erp_lead_id,
      last_error: draft.last_error,
      # Explicit owner contract for the sidebar: the confirmed owner value (ERP
      # User.name), whether it is a sticky manual override, and whether the owner
      # still has to reach ERP (drives the pending/failed status + retry action).
      lead_owner: draft.fields['lead_owner'].to_s,
      lead_owner_override: draft.fields['lead_owner_override'] == true,
      lead_owner_sync_pending: ActiveModel::Type::Boolean.new.cast(draft.fields['lead_owner_sync_pending']),
      updated_at: draft.updated_at
    }
  end
end
# WIJAYA_CUSTOM_END erp_lead_sidebar
