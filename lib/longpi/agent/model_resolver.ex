defmodule Longpi.Agent.ModelResolver do
  @moduledoc """
  Turns a model reference — a tier alias ("J", "Q", "K", or user-defined) or a
  full req_llm spec — into a concrete capability profile.

  Resolution order:

    1. alias match (case-insensitive) against the admin-managed `model_aliases`
       table → its mapped spec + bundled reasoning effort
    2. exact spec match against the configured models
    3. error listing the configured aliases and models, so a caller (usually
       the LLM) can correct itself

  Roles and tools reference tiers instead of hard-coding model names; swapping
  providers only means remapping J/Q/K in the admin UI. A tier is a complete
  profile — model AND reasoning effort — so "K" can mean "strongest model,
  deep reasoning" without the caller knowing either detail.
  """

  @type resolved :: %{spec: String.t() | nil, reasoning_effort: String.t() | nil}

  @doc """
  Resolves `ref` to `%{spec, reasoning_effort}`. `nil`/`""` means "inherit"
  and resolves to a profile of nils.
  """
  @spec resolve(String.t() | nil) :: {:ok, resolved()} | {:error, String.t()}
  def resolve(nil), do: {:ok, %{spec: nil, reasoning_effort: nil}}
  def resolve(""), do: {:ok, %{spec: nil, reasoning_effort: nil}}

  def resolve(ref) when is_binary(ref) do
    ref = String.trim(ref)
    aliases = Longpi.Agent.list_model_aliases!()

    case Enum.find(aliases, &(String.downcase(&1.name) == String.downcase(ref))) do
      %{spec: spec, reasoning_effort: effort} ->
        {:ok, %{spec: spec, reasoning_effort: effort}}

      nil ->
        specs = Longpi.Agent.list_models!() |> Enum.map(& &1.spec)

        if ref in specs do
          {:ok, %{spec: ref, reasoning_effort: nil}}
        else
          {:error, unknown(ref, aliases, specs)}
        end
    end
  end

  defp unknown(ref, aliases, specs) do
    alias_list =
      case aliases do
        [] -> "none configured yet (set J/Q/K in Settings → Models)"
        list -> Enum.map_join(list, ", ", &"#{&1.name} → #{&1.spec}")
      end

    "unknown model \"#{ref}\". Tiers: #{alias_list}. Models: #{Enum.join(specs, ", ")}"
  end
end
