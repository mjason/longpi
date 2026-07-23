defmodule Longpi.Agent.ModelAlias do
  @moduledoc """
  A named model tier, managed from the admin UI: `name` is a stable handle
  ("J", "Q", "K", or a user-defined one) and `spec` points at a configured
  model. Subagent roles and spawn_agent reference tiers instead of hard-coding
  model specs, so swapping providers only means remapping here.

  The built-in poker tiers, by convention: J (Jack) — light & fast, for
  scouting/summarizing; Q (Queen) — balanced, everyday work; K (King) — the
  strongest, deep reasoning.
  """

  use Ash.Resource,
    otp_app: :longpi,
    domain: Longpi.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  sqlite do
    table "model_aliases"
    repo Longpi.Repo
  end

  typescript do
    type_name "ModelAlias"
  end

  actions do
    defaults [:read, :destroy]

    read :list do
      prepare build(sort: [name: :asc])
    end

    # Upsert by name so the admin UI can just "set J = <spec>".
    create :put do
      primary? true
      accept [:name, :spec, :note, :reasoning_effort]
      upsert? true
      upsert_identity :unique_name
      upsert_fields [:spec, :note, :reasoning_effort]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :spec, :string do
      allow_nil? false
      public? true
    end

    # What this tier is for, shown in the admin UI and in resolver errors.
    attribute :note, :string do
      public? true
    end

    # Reasoning effort bundled with the tier (minimal/low/medium/high); nil
    # lets the session's own setting apply. A tier is a complete capability
    # profile: K = strongest model + deep reasoning, J = light + quick.
    attribute :reasoning_effort, :string do
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  identities do
    identity :unique_name, [:name]
  end
end
