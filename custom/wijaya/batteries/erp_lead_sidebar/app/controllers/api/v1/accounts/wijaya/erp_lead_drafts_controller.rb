# WIJAYA_CUSTOM_START erp_lead_sidebar
class Api::V1::Accounts::Wijaya::ErpLeadDraftsController < Api::V1::Accounts::BaseController
  before_action :set_conversation, except: [:options]
  before_action :set_draft, except: [:options]

  def show
    refresh = refresh_from_erp
    render json: serialize(@draft)
      .merge(options: option_values)
      .merge(refresh)
      .merge(configured: erp_configured?)
  end

  # Populates the sidebar select dropdowns from their ERPNext source DocTypes.
  def options
    render json: { options: ::Wijaya::Batteries::ErpLeadSidebar::OptionsService.new.fetch_all }
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

  private

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
    ::Wijaya::Batteries::ErpLeadSidebar::OptionsService.new.fetch_all
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
    ::Wijaya::Batteries::ErpLeadSidebar::Config.erp_configured?
  end

  def permitted_fields
    raw = params[:fields].presence || {}
    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    allowed = ::Wijaya::Batteries::ErpLeadSidebar::PayloadBuilder::DIRECT_FIELDS +
              ::Wijaya::Batteries::ErpLeadSidebar::Config::MARKET_CUSTOMER_FIELDS +
              ::Wijaya::Batteries::ErpLeadSidebar::Config::JENIS_PAKAIAN_FIELDS
    raw.slice(*allowed)
  end

  def serialize(draft)
    {
      id: draft.id,
      conversation_id: draft.conversation_id,
      fields: draft.fields,
      sync_status: draft.sync_status,
      erp_lead_id: draft.erp_lead_id,
      last_error: draft.last_error,
      updated_at: draft.updated_at
    }
  end
end
# WIJAYA_CUSTOM_END erp_lead_sidebar
