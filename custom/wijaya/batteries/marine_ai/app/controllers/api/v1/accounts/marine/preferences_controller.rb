class Api::V1::Accounts::Marine::PreferencesController < Api::V1::Accounts::BaseController
  before_action :current_account
  # Marine preferences back the administrator-only Settings area, so both reading
  # (show) and writing (update) are gated to administrators.
  before_action :authorize_account_update

  def show
    render json: Current.account.marine_preferences
  end

  def update
    Current.account.marine_models = params[:marine_models].permit!.to_h if params[:marine_models].present?
    Current.account.marine_features = params[:marine_features].permit!.to_h if params[:marine_features].present?
    Current.account.save!
    render json: Current.account.marine_preferences
  end

  private

  def authorize_account_update
    authorize Current.account, :update?
  end
end
