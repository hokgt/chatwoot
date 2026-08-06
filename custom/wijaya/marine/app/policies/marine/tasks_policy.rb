class Marine::TasksPolicy < ApplicationPolicy
  def reply_suggestion?
    true
  end

  def rewrite?
    true
  end

  def translate?
    true
  end

  def summarize?
    true
  end

  def follow_up?
    true
  end
end
