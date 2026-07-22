defmodule Longpi.Extensions.HostTest do
  # Exercises the real wasm (QuickJS) extension host — fully self-contained,
  # no external runtime needed, so it runs in the default suite.
  use ExUnit.Case, async: false

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

  test "loads a project extension's tool and executes it in the sandbox", %{cwd: cwd} do
    write_ext(cwd, "hello.js", """
    export default function (longpi) {
      longpi.registerTool({
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
    write_ext(cwd, "num.js", """
    export default function (longpi) {
      longpi.registerTool({
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

  test "fetch() is brokered through Elixir (Req)", %{cwd: cwd} do
    port = start_http_stub(~s({"answer": 42}))

    write_ext(cwd, "fetcher.js", """
    export default function (longpi) {
      longpi.registerTool({
        name: "ask",
        description: "Fetches the answer.",
        parameters: { type: "object", properties: {} },
        async execute() {
          const res = await fetch("http://127.0.0.1:#{port}/answer");
          const data = await res.json();
          return `status=${res.status} answer=${data.answer}`;
        },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert {:ok, "status=200 answer=42"} = Host.call_tool(host, "ask", %{})
  end

  test "longpi.run() executes a system program", %{cwd: cwd} do
    write_ext(cwd, "runner.js", """
    export default function (longpi) {
      longpi.registerTool({
        name: "shell_echo",
        description: "Echoes via the system echo.",
        parameters: { type: "object", properties: { text: { type: "string" } } },
        execute(args) {
          const res = longpi.run("echo", [args.text]);
          return `status=${res.status} out=${res.stdout.trim()}`;
        },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert {:ok, "status=0 out=hola"} = Host.call_tool(host, "shell_echo", %{"text" => "hola"})
  end

  test "console.log goes to stderr and never corrupts the protocol", %{cwd: cwd} do
    write_ext(cwd, "noisy.js", """
    export default function (longpi) {
      console.log("loading noisily");
      longpi.registerTool({
        name: "noisy",
        description: "Logs then answers.",
        parameters: { type: "object", properties: {} },
        execute() { console.log("thinking…"); print("more noise"); return "quiet result"; },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert {:ok, "quiet result"} = Host.call_tool(host, "noisy", %{})
  end

  test "slash commands register and run", %{cwd: cwd} do
    write_ext(cwd, "cmd.js", """
    export default function (longpi) {
      longpi.registerCommand("shout", {
        description: "Uppercases the arg",
        execute(arg) { return String(arg).toUpperCase(); },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert [%{"name" => "shout"}] = Host.commands(host)
    assert {:ok, "HEY"} = Host.call_command(host, "shout", "hey")
  end

  test "reload boots a fresh guest and picks up new files", %{cwd: cwd} do
    write_ext(cwd, "one.js", """
    export default function (longpi) {
      longpi.registerTool({
        name: "one",
        description: "First tool.",
        parameters: { type: "object", properties: {} },
        execute() { return "1"; },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert ["one"] = host |> Host.tool_specs() |> Enum.map(& &1.name)

    write_ext(cwd, "two.js", """
    export default function (longpi) {
      longpi.registerTool({
        name: "two",
        description: "Second tool.",
        parameters: { type: "object", properties: {} },
        execute() { return "2"; },
      });
    }
    """)

    specs = Host.reload(host)
    assert specs |> Enum.map(& &1.name) |> Enum.sort() == ["one", "two"]
    assert {:ok, "2"} = Host.call_tool(host, "two", %{})
  end

  test "a broken extension is reported but doesn't sink the rest", %{cwd: cwd} do
    write_ext(cwd, "broken.js", "this is not { valid js")

    write_ext(cwd, "fine.js", """
    export default function (longpi) {
      longpi.registerTool({
        name: "fine",
        description: "Still works.",
        parameters: { type: "object", properties: {} },
        execute() { return "ok"; },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert ["fine"] = host |> Host.tool_specs() |> Enum.map(& &1.name)
    assert {:ok, "ok"} = Host.call_tool(host, "fine", %{})
  end

  test "a .ts file with plain-JS content still loads (legacy naming)", %{cwd: cwd} do
    write_ext(cwd, "legacy.ts", """
    export default function (longpi) {
      longpi.registerTool({
        name: "legacy",
        description: "Named .ts, written in JS.",
        parameters: { type: "object", properties: {} },
        execute() { return "still here"; },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert ["legacy"] = host |> Host.tool_specs() |> Enum.map(& &1.name)
    assert {:ok, "still here"} = Host.call_tool(host, "legacy", %{})
  end

  test "no extensions anywhere → :none (no guest boots)", %{cwd: cwd} do
    File.rm_rf!(Path.join(cwd, ".longpi/extensions"))
    assert :none = Host.start_for(cwd)
  end

  # Tiny one-shot HTTP server: accept one connection, return a fixed JSON body.
  defp start_http_stub(body) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    Task.start(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 10_000)
      {:ok, _request} = :gen_tcp.recv(sock, 0, 5_000)

      response =
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body

      :gen_tcp.send(sock, response)
      :gen_tcp.close(sock)
      :gen_tcp.close(listen)
    end)

    port
  end
end
