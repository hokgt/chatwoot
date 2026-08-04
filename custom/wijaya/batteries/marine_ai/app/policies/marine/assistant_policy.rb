class Marine::AssistantPolicy < ApplicationPolicy
  def index? = true
  def show? = true
  def playground? = true
  def create? = @account_user.administrator?
  def update? = @account_user.administrator?
  def destroy? = @account_user.administrator?
  def tools? = @account_user.administrator?
  def sync? = @account_user.administrator?
  def product_families? = true
  def product_catalog? = @account_user.administrator?
end
