defmodule Longpi.Agent.Tools.NameSecret do
  @moduledoc """
  Gives a real name to an anonymously provided secret: the user sent just a
  value (`@@=value@@`, stored as `PENDING_XXXX`), and the model — which knows
  the context — decides what it IS and names it. The value moves to the new
  name inside the store; it never passes through the model.

  Only PENDING_* handles can be renamed: real secrets are managed by the user
  (chat markers or the admin UI), not shuffled around by the model.
  """

  @behaviour Longpi.Agent.Tool

  alias Longpi.Agent.SecretCapture

  @impl true
  def name, do: "name_secret"

  @impl true
  def description do
    "Assign the real name to a pending secret. When a message shows " <>
      "\"[unnamed secret stored as PENDING_XXXX...]\", infer from context what " <>
      "the value is for and call this with that handle and an env-style name " <>
      "(e.g. HOME_ASSISTANT_TOKEN). After renaming, process.env.<name> is " <>
      "available to extensions."
  end

  @impl true
  def parameter_schema do
    [
      pending: [
        type: :string,
        required: true,
        doc: "The PENDING_XXXX handle shown in the user's message"
      ],
      name: [
        type: :string,
        required: true,
        doc: "The real name: A-Z, 0-9, _, starting with a letter (e.g. GITHUB_TOKEN)"
      ]
    ]
  end

  @impl true
  def run(%{pending: pending, name: name}, _ctx) do
    secrets = all_secrets()

    cond do
      not SecretCapture.pending?(pending) ->
        {:error, "#{pending} is not a pending handle — only PENDING_* secrets can be named"}

      not Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, name) ->
        {:error, "invalid name #{inspect(name)} — use A-Z, 0-9 and _, starting with a letter"}

      SecretCapture.pending?(name) ->
        {:error, "the new name must not start with PENDING_"}

      true ->
        case Map.fetch(secrets, pending) do
          {:ok, value} ->
            with :ok <- Longpi.Extensions.put_secret(name, value) do
              Longpi.Extensions.delete_secret(pending)
              {:ok, "Secret named #{name}; process.env.#{name} is now available to extensions."}
            else
              {:error, reason} -> {:error, "could not store #{name}: #{inspect(reason)}"}
            end

          :error ->
            pendings =
              secrets |> Map.keys() |> Enum.filter(&SecretCapture.pending?/1) |> Enum.sort()

            hint = if pendings == [], do: "none pending", else: Enum.join(pendings, ", ")
            {:error, "no pending secret #{pending}. Pending: #{hint}"}
        end
    end
  end

  # Includes PENDING_* (secret_env filters them out for extensions; this tool
  # is exactly the place that needs them).
  defp all_secrets do
    case Longpi.Agent.list_extension_secrets() do
      {:ok, secrets} -> Map.new(secrets, &{&1.name, &1.value})
      _ -> %{}
    end
  end
end
