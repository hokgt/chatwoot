module Enterprise::AccountUser
  def permissions
    return super if administrator?

    custom_role.present? ? (custom_role.permissions + ['custom_role']) : super
  end
end
