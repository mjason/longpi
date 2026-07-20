defmodule Longpi.Agent.Conversation do
  @moduledoc "A durable agent conversation: workspace, model, and message history."

  use Ash.Resource,
    otp_app: :longpi,
    domain: Longpi.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  sqlite do
    table "conversations"
    repo Longpi.Repo
  end

  typescript do
    type_name "Conversation"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:title, :cwd, :model]
    end

    update :update do
      primary? true
      accept [:title]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      public? true
    end

    attribute :cwd, :string do
      allow_nil? false
      public? true
    end

    attribute :model, :string do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    has_many :messages, Longpi.Agent.ConversationMessage
  end
end
