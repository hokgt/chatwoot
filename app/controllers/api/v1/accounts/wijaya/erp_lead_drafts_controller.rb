# WIJAYA_CUSTOM_START erp_lead_sidebar
class Api::V1::Accounts::Wijaya::ErpLeadDraftsController < Api::V1::Accounts::BaseController
  before_action :set_conversation, except: [:options]
  before_action :set_draft, except: [:options]

  def show
    render json: serialize(@draft).merge(options: option_values)
  end

  # Populates the sidebar select dropdowns from their ERPNext source DocTypes.
  def options
    render json: { options: ::Wijaya::Batteries::ErpLeadSidebar::OptionsService.new.fetch_all }
  rescue ::Wijaya::Batteries::ErpLeadSidebar::SyncError => e
    render json: { error: e.message, options: {} }, status: :bad_gateway
  end

  def update
    @draft.update!(fields: permitted_fields, sync_status: 'draft', last_error: nil)
    render json: serialize(@draft)
  end

  def sync
    @draft.update!(fields: permitted_fields) if params[:fields].present?
    result = ::Wijaya::Batteries::ErpLeadSidebar::SyncService.new(@draft).perform
    render json: serialize(@draft).merge(payload: result[:payload])
  rescue ::Wijaya::Batteries::ErpLeadSidebar::ValidationError,
         ::Wijaya::Batteries::ErpLeadSidebar::SyncError => e
    @draft.update!(sync_status: 'failed', last_error: e.message)
    render json: serialize(@draft).merge(error: e.message), status: :unprocessable_entity
  end

  private

  def option_values
    ::Wijaya::Batteries::ErpLeadSidebar::OptionsService.new.fetch_all
  rescue ::Wijaya::Batteries::ErpLeadSidebar::SyncError => e
    Rails.logger.warn("Wijaya ERP Lead options unavailable for draft show: #{e.message}")
    {}
  end

  def set_conversation
    # Conversations are addressed by display_id everywhere in the dashboard
    # (the conversation JSON exposes display_id as `id`), so resolve by that.
    @conversation = Current.account.conversations.find_by!(display_id: params[:id])
  end

  def set_draft
    @draft = ::Wijaya::ErpLeadDraft.find_or_create_by!(account: Current.account, conversation: @conversation) do |draft|
      draft.fields = {}
      draft.sync_status = 'draft'
    end
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
