defmodule Longpi.Agent.ExtensionUITest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.ExtensionUI

  defp ui_node(map), do: Jason.encode!(Map.put(map, "__longpi_ui__", true))

  test "flattens a Table to a readable text table for the model" do
    content =
      ui_node(%{
        "type" => "Table",
        "props" => %{"columns" => ["实体", "状态"], "rows" => [["温度", "unavailable"], ["湿度", "45%"]]},
        "children" => []
      })

    assert {:ok, text} = ExtensionUI.model_text(content)
    assert text =~ "实体 | 状态"
    assert text =~ "温度 | unavailable"
    assert text =~ "湿度 | 45%"
    refute text =~ "__longpi_ui__"
  end

  test "flattens a Card with a title and nested content" do
    content =
      ui_node(%{
        "type" => "Card",
        "props" => %{"title" => "家庭状态"},
        "children" => [
          %{"__longpi_ui__" => true, "type" => "Stat", "props" => %{"label" => "在线", "value" => 9}, "children" => []}
        ]
      })

    assert {:ok, text} = ExtensionUI.model_text(content)
    assert text =~ "家庭状态"
    assert text =~ "在线: 9"
  end

  test "passes through a plain (non-UI) result" do
    assert :passthrough = ExtensionUI.model_text("just some text output")
    assert :passthrough = ExtensionUI.model_text(~s({"matched": 9}))
    assert :passthrough = ExtensionUI.model_text(nil)
  end
end
