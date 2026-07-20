defmodule Longpi.Agent.Settings do
  @moduledoc """
  Convenience access to global, admin-editable settings (the `Setting`
  resource). Each key falls back to a code default when unset.

  Known keys:

    * `"system_prompt"` - overrides the default agent system prompt
    * `"default_model"` - model used for new conversations
  """

  @known_keys ~w(system_prompt default_model)

  @doc "Returns the known setting keys (for building an admin UI)."
  def known_keys, do: @known_keys

  @doc "Fetches a setting value, or `default` if unset/blank."
  def get(key, default \\ nil) when is_binary(key) do
    case Longpi.Agent.get_setting_by_key(key, not_found_error?: false) do
      {:ok, %{value: value}} when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  @doc "Creates or updates a setting."
  def put(key, value) when is_binary(key) do
    Longpi.Agent.put_setting(%{key: key, value: value})
  end
end
