defmodule Longpi.Agent.ExtensionUITest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.ExtensionUI

  # What `longpi.ui({ text, view })` serializes to: both halves, explicitly.
  defp envelope(text, view),
    do: Jason.encode!(%{"__longpi_ui__" => true, "text" => text, "view" => view})

  test "returns the author-provided text, never the vdom view" do
    content =
      envelope("9 sensors online; temperature unavailable", %{
        "type" => "Table",
        "props" => %{"columns" => ["实体", "状态"], "rows" => [["温度", "unavailable"]]},
        "children" => []
      })

    assert {:ok, "9 sensors online; temperature unavailable"} = ExtensionUI.model_text(content)
  end

  test "missing text yields an empty string, not a crash" do
    content = Jason.encode!(%{"__longpi_ui__" => true, "view" => %{"type" => "Card"}})
    assert {:ok, ""} = ExtensionUI.model_text(content)
  end

  test "passes through a plain (non-UI) result" do
    assert :passthrough = ExtensionUI.model_text("just some text output")
    assert :passthrough = ExtensionUI.model_text(~s({"matched": 9}))
    assert :passthrough = ExtensionUI.model_text(nil)
  end
end
