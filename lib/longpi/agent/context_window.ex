defmodule Longpi.Agent.ContextWindow do
  @moduledoc """
  Resolves a model's context window and the compaction thresholds derived from
  it. The window is model-specific, so the compaction trigger is a fraction of
  each model's window rather than a fixed token count.

  Window source, in priority order:
    1. the `Model` resource's `context_window` override (admin-editable)
    2. req_llm's model metadata (`limits.context` from LLMDB)
    3. `@default_window` fallback (gateway models LLMDB doesn't know)
  """

  alias Longpi.Agent.Settings

  @default_window 128_000
  @default_ratio 0.8
  @default_keep_ratio 0.3

  @doc "Context window (tokens) for a model spec."
  def for_model(spec) when is_binary(spec) do
    from_resource(spec) || from_req_llm(spec) || @default_window
  end

  @doc "Token count above which a turn triggers compaction (window * ratio)."
  def compaction_threshold(spec) do
    round(for_model(spec) * ratio())
  end

  @doc "Tokens of recent messages to keep verbatim when compacting."
  def keep_tokens(spec) do
    round(for_model(spec) * @default_keep_ratio)
  end

  @doc "Whether compaction is enabled (admin setting, default on)."
  def enabled? do
    Settings.get("compaction_enabled", "true") != "false"
  end

  defp ratio do
    case Float.parse(Settings.get("compaction_ratio", "") || "") do
      {r, _} when r > 0 and r <= 1 -> r
      _ -> @default_ratio
    end
  end

  defp from_resource(spec) do
    case Longpi.Agent.list_models!() |> Enum.find(&(&1.spec == spec)) do
      %{context_window: w} when is_integer(w) and w > 0 -> w
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp from_req_llm(spec) do
    case ReqLLM.model(model_spec(spec)) do
      {:ok, %{limits: %{context: c}}} when is_integer(c) and c > 0 -> c
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Prefer the inline map form so req_llm doesn't warn (with a full stacktrace)
  # on every call for gateway models that aren't in its LLMDB catalog. Unknown
  # providers raise in `to_existing_atom` and fall through to the default.
  defp model_spec(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider, id] -> %{provider: String.to_existing_atom(provider), id: id}
      _ -> spec
    end
  end
end
