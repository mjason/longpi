defmodule Longpi.Agent.ExtensionUI do
  @moduledoc """
  A tool that calls `longpi.ui({ text, view })` returns an envelope carrying
  BOTH halves explicitly: `text` is what the model reads, `view` is the UI tree
  the client renders (TSX → the sandbox's `h()` → `{type, props, children}`).

  The stored result is the whole envelope (the client renders `view`). The model
  must not see the vdom, so `model_text/1` pulls out the author-provided `text` —
  no lossy auto-conversion of the tree, since only the author knows what the
  model should read.
  """

  @doc """
  If `content` is a `longpi.ui` envelope, returns `{:ok, text}` — the explicit
  model-facing text the extension provided. Otherwise `:passthrough` (use the
  content as-is).
  """
  @spec model_text(term()) :: {:ok, String.t()} | :passthrough
  def model_text(content) when is_binary(content) do
    with true <- String.contains?(content, "__longpi_ui__"),
         {:ok, %{"__longpi_ui__" => true} = env} <- Jason.decode(content) do
      {:ok, env |> Map.get("text", "") |> to_string()}
    else
      _ -> :passthrough
    end
  end

  def model_text(_), do: :passthrough
end
