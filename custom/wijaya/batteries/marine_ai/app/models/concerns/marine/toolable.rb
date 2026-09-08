# Marine custom-tool execution has been removed to eliminate all direct outbound
# connectivity between Marine AI and ERP. Marine AI's only allowed outbound path
# is reading from the local marine_catalog PostgreSQL database via the read-only
# catalog connection (Marine::Catalog::Connection + Config).
#
# The module name is preserved for Zeitwerk autoloading, but all request/auth/
# metadata/response builders are now no-ops so nothing can construct or execute
# an outbound tool request.
module Marine::Toolable
  extend ActiveSupport::Concern

  module CustomTools; end

  def tool(*, **) = nil

  def build_request_url(*) = nil

  def build_request_body(*) = nil

  def build_auth_headers(*) = {}

  def build_basic_auth_credentials(*) = nil

  def build_metadata_headers(*) = {}

  def format_response(*) = nil
end
