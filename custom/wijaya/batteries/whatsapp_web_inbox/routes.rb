# frozen_string_literal: true

# Route definitions for the WhatsApp Web (Unofficial) inbox battery. Drawn inside the
# api/v1 `scope module: :accounts` block, resolving to
# Api::V1::Accounts::Wijaya::WhatsappWeb::* controllers. Owned entirely by this battery.
# `:id` on member routes is the native inbox id (the controller scopes it through
# Current.account.inboxes, so cross-account ids resolve to 404).
module Wijaya::Batteries::WhatsappWebInbox::Routes
  module_function

  def draw(mapper)
    mapper.instance_exec do
      namespace :wijaya do
        namespace :whatsapp_web do
          resources :inboxes, only: %i[create show] do
            member do
              get :qr
              post :connect
              post :reconnect
              post :logout
              post :retry
            end
          end
        end
      end
    end
  end
end
