# Marine custom tools have been removed to eliminate all direct outbound
# connectivity between Marine AI and ERP. Every action is denied.
class Marine::CustomToolPolicy < ApplicationPolicy
  def index? = false
  def show? = false
  def create? = false
  def test? = false
  def update? = false
  def destroy? = false
end
