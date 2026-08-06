# Marine copilot messages inherit their thread's access. Account + user scoping
# is enforced in the controller through the parent thread lookup.
class Marine::CopilotMessagePolicy < ApplicationPolicy
  def index? = true
  def create? = true
end
