defmodule Longpi.Agent.Model do
  @moduledoc """
  An LLM the system may use, managed from the admin UI. `spec` is a req_llm
  model string like `"openai:gpt-5.4"` or `"anthropic:claude-sonnet-4-5"`.
  New conversations pick from the enabled models.
  """

  use Ash.Resource,
    otp_app: :longpi,
    domain: Longpi.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  sqlite do
    table "models"
    repo Longpi.Repo
  end

  typescript do
    type_name "Model"
  end

  actions do
    defaults [:read, :destroy]

    read :enabled do
      filter expr(enabled == true)
      prepare build(sort: [position: :asc, label: :asc])
    end

    read :list do
      prepare build(sort: [position: :asc, label: :asc])
    end

    create :create do
      primary? true
      accept [:spec, :label, :enabled, :position]
    end

    update :update do
      primary? true
      accept [:spec, :label, :enabled, :position]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :spec, :string do
      allow_nil? false
      public? true
    end

    attribute :label, :string do
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :position, :integer do
      allow_nil? false
      default 0
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  identities do
    identity :unique_spec, [:spec]
  end
end
