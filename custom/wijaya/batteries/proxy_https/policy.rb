require Rails.root.join('custom/wijaya/batteries/proxy_https/proxy_scheme_middleware')

# Loaded directly by the marked production.rb touchpoint before Rails builds its middleware stack.
# Keep the standalone nested namespace so the hook does not depend on battery-loader timing.
# rubocop:disable Style/ClassAndModuleChildren
module Wijaya
  module Batteries
    module ProxyHttps
      class Policy
        INSTALLED_FLAG = :@wijaya_proxy_https_middleware_installed

        def self.apply!(config, env: ENV)
          enabled = ActiveModel::Type::Boolean.new.cast(env.fetch('FORCE_SSL', false))
          config.force_ssl = enabled
          config.assume_ssl = false
          install_proxy_scheme_middleware!(config) if enabled
        end

        def self.install_proxy_scheme_middleware!(config)
          return if config.instance_variable_defined?(INSTALLED_FLAG)

          config.middleware.insert_before(0, ProxySchemeMiddleware)
          config.instance_variable_set(INSTALLED_FLAG, true)
        end
        private_class_method :install_proxy_scheme_middleware!
      end
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
