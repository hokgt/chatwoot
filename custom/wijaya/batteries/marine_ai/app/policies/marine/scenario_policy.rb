class Marine::ScenarioPolicy < ApplicationPolicy
  def index? = true
  def show? = true
  def create? = @account_user.administrator?
  def update? = @account_user.administrator?
  def destroy? = @account_user.administrator?
end
