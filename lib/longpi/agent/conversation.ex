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
    defaults [:read]

    create :create do
      primary? true
      accept [:title, :cwd, :model, :system_prompt, :reasoning_effort, :agent_role, :parent_id]
    end

    # Delete children first, then the row. Their FKs have no ON DELETE CASCADE
    # (SQLite can't alter one in place), so without this the destroy fails on any
    # conversation that has messages OR compactions and the row reappears on
    # refresh. after_action?: false ⇒ children go BEFORE the parent.
    destroy :destroy do
      primary? true
      # Subagent children go first (recursively cleaning their own messages),
      # then this conversation's own dependents.
      change cascade_destroy(:children, return_notifications?: false, after_action?: false)
      change cascade_destroy(:messages, return_notifications?: false, after_action?: false)
      change cascade_destroy(:compactions, return_notifications?: false, after_action?: false)

      # Stop any live Session once the row is gone, so it can't keep running and
      # later crash trying to persist to a deleted conversation. No-op if none.
      change fn changeset, _context ->
        id = changeset.data.id

        Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
          case result do
            {:error, _} -> :ok
            _ -> Longpi.Agent.Sessions.stop(id)
          end

          result
        end)
      end
    end

    update :update do
      primary? true
      accept [:title, :model, :system_prompt, :reasoning_effort]
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

    # Per-conversation system prompt override; nil falls back to the global
    # setting, then the code default. Supports `{{cwd}}` interpolation.
    attribute :system_prompt, :string do
      public? true
      constraints allow_empty?: true, trim?: false
    end

    # Reasoning effort passed to the model ("minimal" | "low" | "medium" |
    # "high"); nil = don't send one (the model's default). req_llm maps it per
    # provider — OpenAI reasoning_effort, Anthropic thinking budget, etc.
    attribute :reasoning_effort, :string do
      public? true
    end

    # Set on subagent conversations: the agent-definition name ("scout",
    # "worker", …) this child was spawned as. nil = a normal top-level
    # conversation.
    attribute :agent_role, :string do
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    has_many :messages, Longpi.Agent.ConversationMessage
    has_many :compactions, Longpi.Agent.Compaction

    # Subagent tree: children are conversations spawned by this one's agent.
    belongs_to :parent, __MODULE__ do
      public? true
      attribute_writable? true
    end

    has_many :children, __MODULE__, destination_attribute: :parent_id
  end
end
