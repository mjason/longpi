defmodule Longpi.Agent.ScheduledTask do
  @moduledoc """
  A cron-scheduled task bound to a conversation: at every match of `cron`
  (standard 5-field Linux expression, server-local time) the scheduler injects
  `task` into the conversation as a user message and the agent runs a turn.

  Rows live in the DB, so schedules survive session reaping AND app restarts —
  the scheduler rebuilds the session from the conversation on demand.
  """

  use Ash.Resource,
    otp_app: :longpi,
    domain: Longpi.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  sqlite do
    table "scheduled_tasks"
    repo Longpi.Repo
  end

  typescript do
    type_name "ScheduledTask"
  end

  actions do
    defaults [:read, :destroy]

    read :list do
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id))
      # id tie-break: two schedules created in the same second (one tool turn
      # can easily do that) must list in a stable order — remove-by-number
      # depends on it.
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :enabled do
      filter expr(enabled == true)
    end

    create :create do
      primary? true
      accept [:conversation_id, :cron, :task, :enabled]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:cron, :task, :enabled, :last_run_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :conversation_id, :uuid do
      allow_nil? false
      public? true
    end

    # Standard 5-field cron: "min hour day month weekday", e.g. "0 23 * * *".
    attribute :cron, :string do
      allow_nil? false
      public? true
    end

    attribute :task, :string do
      allow_nil? false
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :last_run_at, :utc_datetime do
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end
end
