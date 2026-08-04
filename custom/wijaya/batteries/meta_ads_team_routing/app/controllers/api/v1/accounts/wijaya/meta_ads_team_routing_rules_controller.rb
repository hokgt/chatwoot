# WIJAYA_CUSTOM_START meta_ads_team_routing
class Api::V1::Accounts::Wijaya::MetaAdsTeamRoutingRulesController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?
  before_action :fetch_rule, only: [:show, :update, :destroy]

  def index
    @rules = account_rules.includes(:team).order(created_at: :desc)
    render json: @rules.map { |rule| serialize(rule) }
  end

  def show
    render json: serialize(@rule)
  end

  def create
    @rule = account_rules.new(rule_params)
    @rule.save!
    render json: serialize(@rule)
  end

  def update
    @rule.update!(rule_params)
    render json: serialize(@rule)
  end

  def destroy
    @rule.destroy!
    head :ok
  end

  private

  def account_rules
    ::Wijaya::MetaAdsTeamRoutingRule.where(account_id: Current.account.id)
  end

  def fetch_rule
    @rule = account_rules.find(params[:id])
  end

  def rule_params
    params.require(:meta_ads_team_routing_rule).permit(:source_id, :campaign_name, :team_id, :status)
  end

  def serialize(rule)
    {
      id: rule.id,
      account_id: rule.account_id,
      source_id: rule.source_id,
      campaign_name: rule.campaign_name,
      team_id: rule.team_id,
      team_name: rule.team&.name,
      status: rule.status,
      created_at: rule.created_at,
      updated_at: rule.updated_at
    }
  end
end
# WIJAYA_CUSTOM_END meta_ads_team_routing
