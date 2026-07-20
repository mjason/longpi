defmodule Longpi.Agent.Provider do
  @moduledoc """
  Per-provider LLM credentials, editable from the admin UI instead of env vars.

  `name` matches the model spec prefix (`"openai"` for `"openai:gpt-5.4"`).
  `api_key` is sensitive and never exposed over the typescript RPC - the UI
  only learns whether a key is `configured`. Values are stored in plain text
  in the local SQLite db; wrap with Cloak/Ash encryption if that matters.
  """

  use Ash.Resource,
    otp_app: :longpi,
    domain: Longpi.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  sqlite do
    table "providers"
    repo Longpi.Repo
  end

  typescript do
    type_name "Provider"
  end

  actions do
    defaults [:read, :destroy]

    read :list do
      prepare build(sort: [name: :asc])
    end

    read :by_name do
      get_by [:name]
    end

    # Sets name + base_url without touching the stored key.
    create :put do
      primary? true
      upsert? true
      upsert_identity :unique_name
      upsert_fields [:base_url]
      accept [:name, :base_url]
    end

    # Updates only the api_key; blank values are ignored so the UI can leave it
    # unchanged.
    update :set_key do
      argument :api_key, :string, sensitive?: true

      change fn changeset, _ctx ->
        case Ash.Changeset.get_argument(changeset, :api_key) do
          key when is_binary(key) and key != "" ->
            Ash.Changeset.change_attribute(changeset, :api_key, key)

          _ ->
            changeset
        end
      end
    end

    update :clear_key do
      change set_attribute(:api_key, nil)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :base_url, :string do
      public? true
    end

    # Non-public: readable in Elixir (for request injection) but never sent to
    # the browser over the typescript RPC.
    attribute :api_key, :string do
      sensitive? true
      public? false
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  calculations do
    calculate :configured, :boolean, expr(not is_nil(api_key) and api_key != "") do
      public? true
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
