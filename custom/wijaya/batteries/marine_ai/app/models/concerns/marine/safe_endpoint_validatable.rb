# Endpoint validation for Marine custom tools has been removed to eliminate all
# direct outbound connectivity between Marine AI and ERP. Marine AI's only
# allowed outbound path is reading from the local marine_catalog PostgreSQL
# database via the read-only catalog connection (Marine::Catalog::Connection +
# Config). No outbound endpoint URLs exist to validate anymore.
#
# The module name is preserved for Zeitwerk autoloading, but it performs no
# validation.
module Marine::SafeEndpointValidatable
  extend ActiveSupport::Concern
end
