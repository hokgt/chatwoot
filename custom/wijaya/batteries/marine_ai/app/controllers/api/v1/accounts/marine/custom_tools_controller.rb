# Marine custom tools have been removed to eliminate all direct outbound
# connectivity between Marine AI and ERP. Marine AI's only allowed outbound
# path is reading from the local marine_catalog PostgreSQL database via the
# read-only catalog connection (Marine::Catalog::Connection + Config).
#
# The class is kept for Zeitwerk autoloading, but every action returns 404 so
# no custom-tool API surface remains reachable.
class Api::V1::Accounts::Marine::CustomToolsController < Api::V1::Accounts::BaseController
  def index = head :not_found
  def show = head :not_found
  def create = head :not_found
  def update = head :not_found
  def destroy = head :not_found
  def test = head :not_found
end
