# frozen_string_literal: true

require Rails.root.join('custom/wijaya/batteries/core/loader')

# Feature loader for the native WeCom (微信客服) channel battery. It only wires the
# battery's own autoload directories into Zeitwerk; the channel itself is a native
# Channel::Wecom (app/models/channel/wecom.rb) using the standard Channelable
# association, so there is no Inbox monkey-patch to attach here.
#
# Declared in nested (non-compact) module form because the core loader requires
# this file before Zeitwerk has vivified the Wijaya parent constants.
module Wijaya
  module Batteries
    module WecomChannel
      module Loader
        ROOT = Pathname.new(File.expand_path(__dir__))
        AUTOLOAD_DIRS = %w[app/controllers app/services app/jobs].freeze

        module_function

        def setup!
          register_autoload_paths!
        end

        def register_autoload_paths!
          AUTOLOAD_DIRS.each do |relative_path|
            path = ROOT.join(relative_path)
            next unless File.directory?(path)
            next if registered_autoload_path?(path)

            Rails.autoloaders.main.push_dir(path)
          end
        end

        def registered_autoload_path?(path)
          Rails.autoloaders.main.dirs.include?(path.to_s)
        end
      end
    end
  end
end

Wijaya::Batteries::Core::Loader.register(Wijaya::Batteries::WecomChannel::Loader)
