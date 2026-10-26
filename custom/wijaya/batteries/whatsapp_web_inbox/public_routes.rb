# frozen_string_literal: true

# Public (unauthenticated, server-to-server) route definitions for the WhatsApp
# Web inbox battery, drawn from a single marker inside config.rb's
# `public/api/v1` namespace. Resolves to
# Public::Api::V1::Wijaya::WhatsappWeb::ProviderEventsController. Owned entirely
# by this battery; loaded via `require` (not Zeitwerk) so the constant survives
# dev route reloads, mirroring the authenticated routes.rb.
#
# The single endpoint is the connector's signed delivery/read/failed status
# callback. It carries no agent/browser auth — authorization is the exact raw
# body HMAC over the per-inbox Channel::Api secret (see the controller).
module Wijaya::Batteries::WhatsappWebInbox::PublicRoutes
  module_function

  def draw(mapper)
    mapper.instance_exec do
      namespace :wijaya do
        namespace :whatsapp_web do
          # POST /public/api/v1/wijaya/whatsapp_web/provider_events/:inbox_identifier
          post 'provider_events/:inbox_identifier', to: 'provider_events#create'
        end
      end
    end
  end
end
