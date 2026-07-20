defmodule Longpi.Agent.Setting do
  @moduledoc """
  A global, admin-editable key/value setting that overrides a code default.

  Keys are a small fixed set (see `Longpi.Agent.Settings`); values are stored
  as text. Managed from AshAdmin at `/admin`.
  """

  use Ash.Resource,
    otp_app: :longpi,
    domain: Longpi.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  sqlite do
    table "settings"
    repo Longpi.Repo
  end

  typescript do
    type_name "Setting"
  end

  actions do
    defaults [:read, :destroy]

    read :get_by_key do
      get_by [:key]
    end

    create :put do
      primary? true
      upsert? true
      upsert_identity :unique_key
      upsert_fields [:value]
      accept [:key, :value]
    end

    update :update do
      primary? true
      accept [:value]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
    end

    attribute :value, :string do
      public? true
      constraints allow_empty?: true, trim?: false
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  identities do
    identity :unique_key, [:key]
  end
end
