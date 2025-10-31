require 'sidekiq/web'

Sidekiq::Web.use Rack::Auth::Basic do |username, password|
  ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(username), ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_USERNAME"])) &
    ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(password), ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_PASSWORD"]))
end if Rails.env.production?

Rails.application.routes.draw do
  mount Sidekiq::Web => "/sidekiq"
  mount PgHero::Engine, at: "pghero"

  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      post :sync_repositories, to: 'repositories#sync'

      resources :repositories, param: :name, constraints: { name: /[^\/]+/ }, only: [:index, :show] do
        member do
          get :packages, to: 'repositories#packages'
          get :recent, to: 'repositories#recent'
          get :status, to: 'repositories#status'
          post :reindex, to: 'repositories#reindex'
        end
      end
    end
  end

  get '/health', to: 'health#index'
  get '/metrics', to: 'metrics#index'

  get '/404', to: 'errors#not_found'
  get '/422', to: 'errors#unprocessable'
  get '/500', to: 'errors#internal'

  root to: 'home#index'
end
