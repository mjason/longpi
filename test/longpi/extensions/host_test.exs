defmodule Longpi.Extensions.HostTest do
  # Exercises the real Bun extension host. Tagged so it's excluded by default
  # (needs `bun` on PATH); run with `mix test --only extensions`.
  use ExUnit.Case, async: false

  @moduletag :extensions
  @moduletag :tmp_dir

  alias Longpi.Agent.Toolbox
  alias Longpi.Extensions.Host

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".longpi/extensions"))
    %{cwd: dir}
  end

  defp write_ext(cwd, name, contents) do
    File.write!(Path.join([cwd, ".longpi/extensions", name]), contents)
  end

  test "loads a project extension's tool and executes it via Bun", %{cwd: cwd} do
    write_ext(cwd, "hello.ts", """
    export default function (pi) {
      pi.registerTool({
        name: "hello",
        description: "Greets a name.",
        parameters: { type: "object", properties: { name: { type: "string" } }, required: ["name"] },
        execute(args, ctx) { return `Hi ${args.name} from ${ctx.cwd}`; },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    specs = Host.tool_specs(host)

    assert Enum.map(specs, & &1.name) == ["hello"]
    assert %Longpi.Agent.ToolSpec{source: :extension} = hd(specs)
    assert {:ok, "Hi Ada from " <> _} = Host.call_tool(host, "hello", %{"name" => "Ada"})
  end

  test "extension tools merge into a toolbox and run through Toolbox.execute", %{cwd: cwd} do
    write_ext(cwd, "num.ts", """
    export default function (pi) {
      pi.registerTool({
        name: "double",
        description: "Doubles n.",
        parameters: { type: "object", properties: { n: { type: "number" } }, required: ["n"] },
        execute(args) { return String(args.n * 2); },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    toolbox = Toolbox.new() |> Toolbox.with_extensions(Host.tool_specs(host))

    assert "double" in Enum.map(Toolbox.specs(toolbox), & &1.name)
    assert {:ok, "42"} = Toolbox.execute(toolbox, "double", %{"n" => 21}, %{cwd: cwd})
  end

  test "loads a local package dir via its pi.extensions manifest", %{cwd: cwd} do
    pkg = Path.join([cwd, ".longpi/extensions", "greeter"])
    File.mkdir_p!(pkg)

    File.write!(
      Path.join(pkg, "package.json"),
      ~s({"name":"greeter","pi":{"extensions":["ext.ts"]}})
    )

    File.write!(Path.join(pkg, "ext.ts"), """
    export default function (pi) {
      pi.registerTool({ name: "greet", description: "g", parameters: { type: "object" }, execute() { return "hi"; } });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert "greet" in Enum.map(Host.tool_specs(host), & &1.name)
    assert {:ok, "hi"} = Host.call_tool(host, "greet", %{})
  end

  test "bun-installs a file: package and loads its manifest extensions", %{cwd: cwd} do
    # A package that lives outside the workspace, referenced via a file: spec.
    src = Path.join(cwd, "src_pkg")
    File.mkdir_p!(src)

    File.write!(
      Path.join(src, "package.json"),
      ~s({"name":"mytools","version":"1.0.0","pi":{"extensions":["index.ts"]}})
    )

    File.write!(Path.join(src, "index.ts"), """
    export default function (pi) {
      pi.registerTool({ name: "reverse", description: "r",
        parameters: { type: "object", properties: { s: { type: "string" } }, required: ["s"] },
        execute(args) { return [...String(args.s)].reverse().join(""); } });
    }
    """)

    File.write!(
      Path.join([cwd, ".longpi", "packages.json"]),
      Jason.encode!(%{packages: %{"mytools" => "file:#{src}"}})
    )

    {:ok, host} = Host.start_for(cwd)
    assert "reverse" in Enum.map(Host.tool_specs(host), & &1.name)
    assert {:ok, "ipgnol"} = Host.call_tool(host, "reverse", %{"s" => "longpi"})
  end

  test "reload hot-loads a newly written extension (self-evolution)", %{cwd: cwd} do
    write_ext(cwd, "a.ts", """
    export default function (pi) {
      pi.registerTool({ name: "a", description: "a", parameters: { type: "object" }, execute() { return "A"; } });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert Enum.map(Host.tool_specs(host), & &1.name) == ["a"]

    # The agent writes a new extension at runtime, then reloads.
    write_ext(cwd, "b.ts", """
    export default function (pi) {
      pi.registerTool({ name: "b", description: "b", parameters: { type: "object" }, execute() { return "B"; } });
    }
    """)

    assert host |> Host.reload() |> Enum.map(& &1.name) |> Enum.sort() == ["a", "b"]
    assert {:ok, "B"} = Host.call_tool(host, "b", %{})
  end
end
