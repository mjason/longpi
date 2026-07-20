defmodule Longpi.Agent.Compaction do
  @moduledoc """
  A context checkpoint: a summary of the conversation up to `covered_through`
  (a message position). It replaces those messages *only in what we send to
  the LLM* - the original messages stay in the database, so the UI still shows
  the full history and a summary can always be redone.
  """

  use Ash.Resource,
    otp_app: :longpi,
    domain: Longpi.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "compactions"
    repo Longpi.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:conversation_id, :summary, :covered_through, :input_tokens]
    end

    read :latest_for do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id))
      prepare build(sort: [covered_through: :desc], limit: 1)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :summary, :string do
      allow_nil? false
      constraints allow_empty?: false, trim?: false
    end

    # Highest message position folded into this summary.
    attribute :covered_through, :integer do
      allow_nil? false
    end

    # Prompt-token usage that triggered the compaction (for reference/telemetry).
    attribute :input_tokens, :integer

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :conversation, Longpi.Agent.Conversation do
      allow_nil? false
      attribute_writable? true
    end
  end
end
