module Wijaya
  module Marine
    module Loader
      ROOT = Rails.root.join('custom/wijaya/marine')

      def self.setup!
        %w[app/models app/models/concerns app/services app/jobs app/controllers app/policies lib].each do |relative_path|
          path = ROOT.join(relative_path)
          next unless path.directory?

          Rails.autoloaders.main.push_dir(path)
        end

        require_dependency ROOT.join('app/models/concerns/wijaya/marine/account_extensions').to_s
        require_dependency ROOT.join('app/models/concerns/wijaya/marine/inbox_extensions').to_s
        require_dependency ROOT.join('app/services/wijaya/marine/hooks').to_s

        Rails.application.config.to_prepare do
          Account.include Wijaya::Marine::AccountExtensions unless Account < Wijaya::Marine::AccountExtensions
          Inbox.include Wijaya::Marine::InboxExtensions unless Inbox < Wijaya::Marine::InboxExtensions
        end
      end
    end
  end
end
