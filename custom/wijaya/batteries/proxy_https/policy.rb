# Loaded directly by the marked production.rb touchpoint before Rails builds its middleware stack.
# Keep the standalone nested namespace so the hook does not depend on battery-loader timing.
# rubocop:disable Style/ClassAndModuleChildren
module Wijaya
  module Batteries
    module ProxyHttps
      class Policy
        def self.apply!(config, env: ENV)
          enabled = ActiveModel::Type::Boolean.new.cast(env.fetch('FORCE_SSL', false))
          config.force_ssl = enabled
          config.assume_ssl = enabled
        end
      end
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
