# Wires the Marine copilot-thread ownership onto core User without editing
# app/models/user.rb. marine_copilot_threads.user_id has a restrictive database
# foreign key, so a user cannot be deleted while they still own threads. The
# synchronous dependent: :destroy removes those threads (and, through the thread's
# own dependent: :destroy, their messages) in the same transaction before the user
# row, keeping the foreign key satisfied and cleanup callback-driven.
module Wijaya::Marine::UserExtensions
  extend ActiveSupport::Concern

  included do
    has_many :marine_copilot_threads, dependent: :destroy, class_name: 'Marine::CopilotThread'
  end
end
