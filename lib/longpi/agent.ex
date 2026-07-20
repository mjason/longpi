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
  end

  resources do
    resource Longpi.Agent.Conversation do
      define :create_conversation, action: :create
      define :get_conversation, action: :read, get_by: [:id]
      define :list_conversations, action: :read
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
  end
end
