# Marine-owned custom tools API. Mirrors the Captain custom tools controller but
# without any feature flag / premium gate: Marine tools are always available and
# account-scoped. Renders JSON inline to match the existing Marine controllers
# (Marine does not register jbuilder view paths). auth_config is exposed only to
# administrators, matching Captain's serializer behavior.
class Api::V1::Accounts::Marine::CustomToolsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Marine::CustomTool) }
  before_action :set_custom_tool, only: [:show, :update, :destroy]

  def index
    render json: { payload: account_custom_tools.map { |tool| serialize_tool(tool) }, meta: { total_count: account_custom_tools.count, page: 1 } }
  end

  def show
    render json: serialize_tool(@custom_tool)
  end

  def create
    @custom_tool = account_custom_tools.create!(custom_tool_params)
    render json: serialize_tool(@custom_tool), status: :created
  rescue Marine::CustomTool::LimitExceededError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    @custom_tool.update!(custom_tool_params)
    render json: serialize_tool(@custom_tool)
  end

  def destroy
    @custom_tool.destroy
    head :no_content
  end

  def test
    tool = account_custom_tools.new(custom_tool_params)
    body = execute_test_request(tool)
    render json: { status: 200, body: body.to_s.truncate(500) }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_custom_tool
    @custom_tool = account_custom_tools.find(params[:id])
  end

  def account_custom_tools
    @account_custom_tools ||= Current.account.marine_custom_tools
  end

  def execute_test_request(tool)
    http_tool = Marine::Tools::HttpTool.new(nil, tool)
    http_tool.send(:execute_http_request, tool.endpoint_url, nil, nil)
  end

  def serialize_tool(tool)
    payload = {
      id: tool.id,
      slug: tool.slug,
      title: tool.title,
      description: tool.description,
      endpoint_url: tool.endpoint_url,
      http_method: tool.http_method,
      request_template: tool.request_template,
      response_template: tool.response_template,
      auth_type: tool.auth_type,
      param_schema: tool.param_schema,
      enabled: tool.enabled,
      account_id: tool.account_id,
      created_at: tool.created_at.to_i,
      updated_at: tool.updated_at.to_i
    }
    payload[:auth_config] = tool.auth_config if Current.user&.administrator?
    payload
  end

  def custom_tool_params
    params.require(:custom_tool).permit(
      :title,
      :description,
      :endpoint_url,
      :http_method,
      :request_template,
      :response_template,
      :auth_type,
      :enabled,
      auth_config: {},
      param_schema: [:name, :type, :description, :required]
    )
  end
end
