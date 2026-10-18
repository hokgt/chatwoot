# frozen_string_literal: true

# Top-level, unauthenticated corp-scoped WeCom callback routes. Loaded via `require`
# (not Zeitwerk) from a thin marker block in config/routes.rb so the constant
# survives dev route reloads. Mirrors the other channel webhook routes
# (webhooks/line, webhooks/whatsapp, ...) but keeps the definition inside the
# battery. The handler is Webhooks::WecomController (battery-owned, autoloaded).
module Wijaya
  module Batteries
    module WecomChannel
      module Routes
        module_function

        def draw(mapper)
          mapper.instance_exec do
            get 'webhooks/wecom/:corp_id', to: 'webhooks/wecom#verify'
            post 'webhooks/wecom/:corp_id', to: 'webhooks/wecom#events'
          end
        end
      end
    end
  end
end
