defmodule Longpi.Agent do
  @moduledoc """
  Agent domain: conversations and their persisted messages.

  Process-side APIs (running sessions) live in `Longpi.Agent.Sessions`;
  this domain owns the durable state.
  """

  use Ash.Domain, otp_app: :longpi, extensions: [AshAdmin.Domain, AshTypescript.Rpc]

  admin do
    show? true
  end

  typescript_rpc do
    resource Longpi.Agent.Conversation do
      rpc_action :list_conversations, :read
      rpc_action :get_conversation, :read, get_by: [:id]
      rpc_action :create_conversation, :create
      rpc_action :update_conversation, :update
      rpc_action :destroy_conversation, :destroy
    end

    resource Longpi.Agent.Setting do
      rpc_action :list_settings, :read
      rpc_action :put_setting, :put
      rpc_action :update_setting, :update
    end

    resource Longpi.Agent.Model do
      rpc_action :list_models, :list
      rpc_action :list_enabled_models, :enabled
      rpc_action :create_model, :create
      rpc_action :update_model, :update
      rpc_action :destroy_model, :destroy
    end

    resource Longpi.Agent.Provider do
      rpc_action :list_providers, :list
      rpc_action :put_provider, :put
      rpc_action :set_provider_key, :set_key
      rpc_action :clear_provider_key, :clear_key
      rpc_action :destroy_provider, :destroy
    end
  end

  resources do
    resource Longpi.Agent.Conversation do
      define :create_conversation, action: :create
      define :get_conversation, action: :read, get_by: [:id]
      define :list_conversations, action: :read
      define :update_conversation, action: :update
      define :destroy_conversation, action: :destroy
    end

    resource Longpi.Agent.ConversationMessage do
      define :append_message, action: :create
      define :list_messages, action: :for_conversation, args: [:conversation_id]
    end

    resource Longpi.Agent.Setting do
      define :put_setting, action: :put
      define :get_setting_by_key, action: :get_by_key, args: [:key]
      define :list_settings, action: :read
    end

    resource Longpi.Agent.Model do
      define :create_model, action: :create
      define :list_models, action: :list
      define :list_enabled_models, action: :enabled
      define :update_model, action: :update
      define :destroy_model, action: :destroy
    end

    resource Longpi.Agent.Provider do
      define :put_provider, action: :put
      define :get_provider_by_name, action: :by_name, args: [:name]
      define :list_providers, action: :list
      define :set_provider_key, action: :set_key
    end

    resource Longpi.Agent.Compaction do
      define :create_compaction, action: :create
      define :latest_compaction, action: :latest_for, args: [:conversation_id]
    end
  end
end
