# frozen_string_literal: true

# Route definitions for the ERP Lead sidebar battery. Drawn inside the api/v1
# `scope module: :accounts` block, resolving to Api::V1::Accounts::Wijaya::*
# controllers. Owned entirely by this battery.
module Wijaya::Batteries::ErpLeadSidebar::Routes
  module_function

  def draw(mapper) # rubocop:disable Metrics/MethodLength
    mapper.instance_exec do
      namespace :wijaya do
        resources :erp_lead_drafts, only: %i[show update] do
          member do
            post :sync
            # Dedicated validated Lead Owner set/reset (never a generic field allowlist).
            post :owner
          end
          collection do
            get :options
          end
          # Manual Lead Activity form, nested under the draft (addressed by the
          # conversation display_id). Independent, lazily-loaded read endpoints for
          # the Activity Master and the Person In Charge directory (each hits only
          # its own ERP dependency), a lightweight ERP-free metadata endpoint for the
          # default date, and a single guarded insert.
          resources :lead_activities, only: %i[create] do
            collection do
              get :meta
              get :activity_options
              get :person_in_charge_options
            end
          end
        end
        # Account-scoped singleton ERPNext connection settings (admin-only).
        resource :erp_setting, only: %i[show update] do
          post :test
        end
      end
    end
  end
end
