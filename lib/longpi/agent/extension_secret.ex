defmodule Longpi.Agent.ExtensionSecret do
  @moduledoc """
  A named secret (e.g. an API key) exposed to the extension host as an
  environment variable, stored in the app database instead of the machine's
  environment. Extensions read it via `process.env.<NAME>`.

  `value` is sensitive and never leaves the server — the admin UI lists only
  the names and whether each is set, and the value is injected straight into
  the host process. Stored in the local SQLite db; wrap with Cloak/Ash
  encryption if that matters for your threat model (same as `Provider.api_key`).
  """

  use Ash.Resource,
    otp_app: :longpi,
    domain: Longpi.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "extension_secrets"
    repo Longpi.Repo
  end

  actions do
    defaults [:read, :destroy]

    # Upsert by name so re-saving a key replaces its value.
    create :put do
      primary? true
      upsert? true
      upsert_identity :unique_name
      upsert_fields [:value]
      accept [:name, :value]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    # Never public: kept out of any typescript RPC payload.
    attribute :value, :string do
      allow_nil? false
      sensitive? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name, [:name]
  end
end
