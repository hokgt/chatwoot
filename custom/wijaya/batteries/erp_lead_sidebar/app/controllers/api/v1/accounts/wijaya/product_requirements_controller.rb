# WIJAYA_CUSTOM_START erp_lead_sidebar
# Account-scoped list/create for the ERP Lead "Product Requirement" Link field,
# backed by the EXISTING ERPNext DocType "Lead Product Requirements". Every
# account agent who can reach the ERP Lead form may list/select/create (no
# admin-only gate — ERP integration-user permissions remain authoritative). It
# is master data, not conversation-scoped, so it is not nested under a draft.
class Api::V1::Accounts::Wijaya::ProductRequirementsController < Api::V1::Accounts::BaseController
  # Bounded, searchable list of { value: ERP name, label: product_name }.
  def index
    return render_unconfigured unless erp_configured?

    options = service.list(query: params[:q], limit: params[:limit])
    render json: { options: options }
  rescue ::Wijaya::Batteries::ErpLeadSidebar::SyncError
    # Never surface the raw ERPNext response/exception to the agent.
    render json: { error: 'Product Requirements are currently unavailable.', options: [] }, status: :bad_gateway
  end

  # Creates a Lead Product Requirement from product_name + raw numeric
  # product_price only. A server-side normalized duplicate returns the existing
  # record (zero create call) with a truthful message.
  def create
    return render_unconfigured unless erp_configured?

    result = service.create(
      product_name: product_requirement_params[:product_name],
      product_price: product_requirement_params[:product_price]
    )
    render json: create_response(result), status: result[:duplicate] ? :ok : :created
  rescue ::Wijaya::Batteries::ErpLeadSidebar::ValidationError => e
    # Locally generated validation messages are safe to surface.
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ::Wijaya::Batteries::ErpLeadSidebar::SyncError
    render json: { error: 'Could not create the Product Requirement. Please try again.' }, status: :bad_gateway
  end

  private

  def service
    ::Wijaya::Batteries::ErpLeadSidebar::ProductRequirementsService.new(Current.account)
  end

  def create_response(result)
    message =
      if result[:duplicate]
        'A matching Product Requirement already exists; selecting it.'
      else
        'Product Requirement created.'
      end
    { value: result[:value], label: result[:label], duplicate: result[:duplicate], message: message }
  end

  # Only product_name/product_price are ever accepted; the browser can never set
  # the ERP document name or any other DocType field.
  def product_requirement_params
    params.permit(:product_name, :product_price)
  end

  def erp_configured?
    ::Wijaya::Batteries::ErpLeadSidebar::Config.erp_configured?(Current.account)
  end

  def render_unconfigured
    render json: { configured: false, error: 'ERP connection is not configured.' }, status: :unprocessable_entity
  end
end
# WIJAYA_CUSTOM_END erp_lead_sidebar
