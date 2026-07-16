Rails.application.routes.draw do
  root "landing#index"

  get "signup", to: "registrations#new"
  post "signup", to: "registrations#create"
  get "terms", to: "legal#terms", as: :terms
  get "privacy", to: "legal#privacy", as: :privacy
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
    resources :ai_traces, only: [:index, :show]
    resource :ai_settings, only: [:show, :update], controller: :ai_settings
    get "stats", to: "stats#index", as: :stats
  end

  resources :properties do
    post :copy_content, on: :member
    get :whatsapp_qr, on: :member
    patch :co_host, action: :update_co_host, on: :member
    resources :knowledge_blocks, except: [:show]
    resources :recommendations, except: [:show]
    resources :faqs, except: [:show]
  end

  resources :conversations, only: [:index, :show] do
    post :reply, on: :member
    get :refresh, on: :member
  end
  resources :guest_requests, path: "pedidos", only: [:index, :show, :update], defaults: { kind: "request" }
  resources :inquiries, path: "consultas", controller: "guest_requests", only: [:index, :show, :update], defaults: { kind: "inquiry" }
  resources :alerts, only: [:index, :show, :update] do
    post :answer_question, on: :member
  end
  resources :checkout_events, path: "salidas", only: [:index, :show, :update]

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
    post :whatsapp_status, to: "whatsapp_status#create"
    post :stripe, to: "stripe#create"
  end

  namespace :internal do
    namespace :ai do
      scope "tools", controller: :tools do
        post :property_brain
        post :sensitive_access_info
        post :guest_context
        post :stay_facts
        post :search_property_knowledge
        post :approved_recommendations
        post :access_instructions
        post :property_policy
        post :escalation_draft
      end
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
end
