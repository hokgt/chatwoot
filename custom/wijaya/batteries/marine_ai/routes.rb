# frozen_string_literal: true

# Route definitions for the Marine AI battery. Drawn inside the api/v1
# `scope module: :accounts` block, so all endpoints resolve to
# Api::V1::Accounts::Marine::* controllers. Owned entirely by this battery;
# the native config/routes.rb keeps only a single generic draw call.
module Wijaya::Marine::Routes
  module_function

  def draw(mapper) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    mapper.instance_exec do
      namespace :marine do
        resource :preferences, only: %i[show update]
        resource :provisioning, only: %i[show create], controller: 'provisioning' do
          post :downgrade, on: :collection
          post :revoke_all, on: :collection
          get :privileges, on: :collection
        end
        resource :llm_settings, only: %i[show update] do
          post :test, on: :collection
        end
        resources :tasks, only: [] do
          collection do
            post :reply_suggestion
            post :rewrite
            post :summarize
            post :translate
            post :follow_up
          end
        end
        resources :assistants do
          member do
            post :playground
          end
          resources :inboxes, only: %i[index create destroy], param: :inbox_id
          resources :scenarios
          resources :copilot_threads, only: %i[index show create destroy] do
            resources :copilot_messages, only: %i[index create]
          end
        end
        resources :assistant_responses
        resources :documents, only: %i[index show create destroy] do
          post :sync, on: :member
          collection do
            get :product_families
            post :product_catalog
          end
        end
        resources :custom_tools, only: %i[index show create update destroy] do
          post :test, on: :collection
        end
      end
    end
  end
end
