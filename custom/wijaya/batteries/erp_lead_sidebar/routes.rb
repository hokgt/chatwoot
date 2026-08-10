# frozen_string_literal: true

# Route definitions for the ERP Lead sidebar battery. Drawn inside the api/v1
# `scope module: :accounts` block, resolving to Api::V1::Accounts::Wijaya::*
# controllers. Owned entirely by this battery.
module Wijaya::Batteries::ErpLeadSidebar::Routes
  module_function

  def draw(mapper)
    mapper.instance_exec do
      namespace :wijaya do
        resources :erp_lead_drafts, only: %i[show update] do
          member do
            post :sync
          end
          collection do
            get :options
          end
          # Manual Lead Activity form, nested under the draft (addressed by the
          # conversation display_id). Only runtime options + a guarded insert.
          resources :lead_activities, only: %i[create] do
            collection do
              get :options
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
