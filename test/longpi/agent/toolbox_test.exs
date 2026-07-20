defmodule Longpi.Agent.ToolboxTest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.Toolbox

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{ctx: %{cwd: dir}}
  end

  test "default toolbox exposes the four built-in tools" do
    names = Toolbox.new() |> Toolbox.modules() |> Enum.map(& &1.name()) |> Enum.sort()
    assert names == ["bash", "edit", "read", "write"]
  end

  test "executes a tool with string-keyed args from JSON", %{tmp_dir: dir, ctx: ctx} do
    File.write!(Path.join(dir, "f.txt"), "content-here")

    assert {:ok, text} = Toolbox.execute(Toolbox.new(), "read", %{"path" => "f.txt"}, ctx)
    assert text =~ "content-here"
  end

  test "applies schema defaults", %{tmp_dir: dir, ctx: ctx} do
    path = Path.join(dir, "d.txt")
    File.write!(path, "aaa bbb aaa")

    # replace_all defaults to false -> ambiguity error mentions the count
    args = %{"path" => path, "old_string" => "aaa", "new_string" => "ccc"}
    assert {:error, message} = Toolbox.execute(Toolbox.new(), "edit", args, ctx)
    assert message =~ "2"
  end

  test "rejects invalid argument types with a readable message", %{ctx: ctx} do
    args = %{"path" => "f.txt", "offset" => "not-a-number"}
    assert {:error, message} = Toolbox.execute(Toolbox.new(), "read", args, ctx)
    assert message =~ "offset"
  end

  test "rejects missing required args", %{ctx: ctx} do
    assert {:error, message} = Toolbox.execute(Toolbox.new(), "read", %{}, ctx)
    assert message =~ "path"
  end

  test "ignores unknown extra args", %{tmp_dir: dir, ctx: ctx} do
    File.write!(Path.join(dir, "g.txt"), "ok")
    args = %{"path" => "g.txt", "hallucinated_option" => true}
    assert {:ok, _} = Toolbox.execute(Toolbox.new(), "read", args, ctx)
  end

  test "unknown tool name is an error naming the tool", %{ctx: ctx} do
    assert {:error, message} = Toolbox.execute(Toolbox.new(), "teleport", %{}, ctx)
    assert message =~ "teleport"
  end
end
