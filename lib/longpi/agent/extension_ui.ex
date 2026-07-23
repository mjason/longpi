defmodule Longpi.Agent.ExtensionUI do
  @moduledoc """
  When an extension tool returns a UI tree (TSX → the sandbox's `h()` →
  `{__longpi_ui__, type, props, children}` JSON), the stored result — which the
  client renders — is that tree. But the model needs readable content, not a
  vdom dump. `model_text/1` flattens the tree to plain text for the LLM context;
  the frontend keeps rendering the tree.
  """

  @doc """
  If `content` is a UI tree, returns `{:ok, plain_text}` for the model; otherwise
  `:passthrough` (use the content as-is).
  """
  @spec model_text(term()) :: {:ok, String.t()} | :passthrough
  def model_text(content) when is_binary(content) do
    with true <- String.contains?(content, "__longpi_ui__"),
         {:ok, %{"__longpi_ui__" => true} = node} <- Jason.decode(content) do
      {:ok, node |> flatten() |> String.trim()}
    else
      _ -> :passthrough
    end
  end

  def model_text(_), do: :passthrough

  defp flatten(node) when is_map(node) do
    props = node["props"] || %{}
    children = node["children"] || []

    case node["type"] do
      "Table" -> flatten_table(props)
      "Stat" -> "#{value(props["label"])}: #{value(props["value"])}"
      "Badge" -> value(props["text"] || flatten_children(children))
      "Card" -> join([value(props["title"]), flatten_children(children)])
      _ -> flatten_children(children)
    end
  end

  defp flatten(text) when is_binary(text), do: text
  defp flatten(n) when is_number(n), do: to_string(n)
  defp flatten(_), do: ""

  defp flatten_children(children) when is_list(children),
    do: children |> Enum.map(&flatten/1) |> join()

  defp flatten_children(_), do: ""

  defp flatten_table(props) do
    columns = props["columns"] || []
    rows = props["rows"] || []

    header = if columns == [], do: "", else: Enum.map_join(columns, " | ", &value/1)

    body =
      Enum.map_join(rows, "\n", fn row ->
        row |> List.wrap() |> Enum.map_join(" | ", &value/1)
      end)

    join([header, body])
  end

  defp join(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n")

  defp value(nil), do: ""
  defp value(v) when is_binary(v), do: v
  defp value(v), do: to_string(v)
end
