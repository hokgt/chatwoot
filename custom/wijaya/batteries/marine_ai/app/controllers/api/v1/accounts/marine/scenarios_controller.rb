# Marine-owned scenarios API. Mirrors the Captain scenarios controller but
# without any feature flag / premium gate: Marine scenarios are always available
# and account-scoped through the assistant. Renders JSON inline to match the
# existing Marine controllers (Marine does not register jbuilder view paths).
class Api::V1::Accounts::Marine::ScenariosController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Marine::Scenario) }
  before_action :set_assistant
  before_action :set_scenario, only: [:show, :update, :destroy]

  def index
    scenarios = assistant_scenarios.enabled
    render json: { payload: scenarios.map { |scenario| serialize_scenario(scenario) }, meta: { total_count: scenarios.count, page: 1 } }
  end

  def show
    render json: serialize_scenario(@scenario)
  end

  def create
    @scenario = assistant_scenarios.create!(scenario_params.merge(account: Current.account))
    render json: serialize_scenario(@scenario), status: :created
  end

  def update
    @scenario.update!(scenario_params)
    render json: serialize_scenario(@scenario)
  end

  def destroy
    @scenario.destroy
    head :no_content
  end

  private

  def set_assistant
    @assistant = account_assistants.find(params[:assistant_id])
  end

  def account_assistants
    @account_assistants ||= Current.account.marine_assistants
  end

  def set_scenario
    @scenario = assistant_scenarios.find(params[:id])
  end

  def assistant_scenarios
    @assistant.scenarios
  end

  def scenario_params
    params.require(:scenario).permit(:title, :description, :instruction, :enabled, tools: [])
  end

  def serialize_scenario(scenario)
    {
      id: scenario.id,
      title: scenario.title,
      description: scenario.description,
      instruction: scenario.instruction,
      tools: scenario.tools,
      enabled: scenario.enabled,
      assistant_id: scenario.assistant_id,
      account_id: scenario.account_id,
      created_at: scenario.created_at,
      updated_at: scenario.updated_at,
      assistant: { id: scenario.assistant.id, name: scenario.assistant.name }
    }
  end
end
