# Marine copilot threads are usable by administrators and agents. Cross-account
# and cross-user isolation is enforced in the controller (threads are always
# scoped to Current.account + Current.user), so read/use is broadly allowed here.
class Marine::CopilotThreadPolicy < ApplicationPolicy
  def index? = true
  def show? = true
  def create? = true
  def destroy? = true
end
