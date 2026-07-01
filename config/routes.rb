Rails.application.routes.draw do
  root "landing#index"

  get "signup", to: "registrations#new"
  post "signup", to: "registrations#create"
  get "verify-email", to: "email_verifications#show", as: :verify_email
  post "verify-email", to: "email_verifications#create", as: :resend_verification_email
  get "login", to: "sessions#new"
  post "login", to: "sessions#create"
  delete "logout", to: "sessions#destroy"

  get "dashboard", to: "dashboard#index"

  namespace :admin do
    root to: redirect("/admin/users")
    resources :users, only: [:index] do
      member do
        post :extend_subscription
        patch :update_role
      end
    end
    resources :errors, only: [:index, :show] do
      patch :resolve, on: :member
    end
    get "stats", to: "stats#index", as: :stats
  end

  resources :properties do
    post :copy_content, on: :member
    get :whatsapp_qr, on: :member
    resources :knowledge_blocks, except: [:show]
    resources :recommendations, except: [:show]
    resources :faqs, except: [:show]
  end

  resources :recommendations, only: [:index]
  resources :conversations, only: [:index, :show]
  resources :alerts, only: [:index, :show, :update] do
    post :answer_question, on: :member
  end
  resources :guests, only: [:index, :show]

  resource :subscription, path: "subscriptions", only: [:show], controller: :billing do
    get :pricing
    post :checkout
    post :portal
  end

  resource :billing, only: [:show], controller: :billing do
    get :pricing
    post :checkout
    post :portal
  end

  resource :settings, only: [:show, :update]

  namespace :webhooks do
    post :whatsapp, to: "whatsapp#create"
    post :stripe, to: "stripe#create"
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
end
