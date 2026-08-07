require 'agents'

# The Marine HTTP custom-tool executor has been removed to eliminate all direct
# outbound connectivity between Marine AI and ERP. Marine AI's only allowed
# outbound path is reading from the local marine_catalog PostgreSQL database via
# the read-only catalog connection (Marine::Catalog::Connection + Config).
#
# The class is kept for Zeitwerk autoloading, but instantiation now raises so no
# code path can perform outbound HTTP requests through it.
class Marine::Tools::HttpTool < Agents::Tool
  def initialize(*)
    raise 'Marine::Tools::HttpTool has been removed to eliminate Marine AI outbound ERP connectivity'
  end
end
