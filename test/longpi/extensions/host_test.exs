defmodule Longpi.Extensions.HostTest do
  # Exercises the real native QuickJS (rquickjs) extension host — self-contained,
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
    # ctx.cwd must be the real workspace, not undefined (asserted in full).
    assert {:ok, "Hi Ada from #{cwd}"} == Host.call_tool(host, "hello", %{"name" => "Ada"})
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
        async execute(args) {
          const res = await longpi.run("echo", [args.text]);
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

  test "a .ts file with real TypeScript type syntax loads (types stripped)", %{cwd: cwd} do
    write_ext(cwd, "typed.ts", """
    function label(n: number): string {
      return `#${n}`;
    }

    export default function (longpi: any) {
      longpi.registerTool({
        name: "typed",
        description: "Uses TS type annotations.",
        parameters: { type: "object", properties: { n: { type: "number" } } },
        async execute(args: { n: number }) {
          const items = (args.n ? [args.n] : []) as Array<number>;
          return label(items.length);
        },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert ["typed"] = host |> Host.tool_specs() |> Enum.map(& &1.name)
    assert {:ok, "#1"} = Host.call_tool(host, "typed", %{"n" => 5})
  end

  test "a .tsx tool returns a longpi.ui envelope: explicit text + a view tree", %{cwd: cwd} do
    write_ext(cwd, "status.tsx", """
    export default function (longpi: any) {
      longpi.registerTool({
        name: "home_status",
        description: "Shows a status table.",
        parameters: { type: "object", properties: {} },
        execute() {
          const rows = [["温度", "unavailable"], ["湿度", "45%"]];
          return longpi.ui({
            text: `2 sensors — ${rows.map((r) => r.join(": ")).join("; ")}`,
            view: (
              <Card title="家庭状态">
                <Table columns={["实体", "状态"]} rows={rows} />
              </Card>
            ),
          });
        },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert {:ok, result} = Host.call_tool(host, "home_status", %{})

    # The stored result carries BOTH halves. The client will render `view`...
    assert %{"__longpi_ui__" => true, "text" => text, "view" => view} = Jason.decode!(result)
    assert view["type"] == "Card"
    assert view["props"]["title"] == "家庭状态"
    assert hd(view["children"])["type"] == "Table"

    # ...while the model receives only the author-provided text, never the tree.
    assert text == "2 sensors — 温度: unavailable; 湿度: 45%"
    assert {:ok, ^text} = Longpi.Agent.ExtensionUI.model_text(result)
  end

  test "no extensions anywhere → :none (no guest boots)", %{cwd: cwd} do
    File.rm_rf!(Path.join(cwd, ".longpi/extensions"))
    assert :none = Host.start_for(cwd)
  end

  test "setTimeout resolves an awaited promise mid-call", %{cwd: cwd} do
    write_ext(cwd, "timer.js", """
    export default function (longpi) {
      longpi.registerTool({
        name: "delayed",
        description: "Waits then answers.",
        parameters: { type: "object", properties: {} },
        async execute() {
          await new Promise((resolve) => setTimeout(resolve, 5));
          return "tick";
        },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert {:ok, "tick"} = Host.call_tool(host, "delayed", %{})
  end

  test "structuredClone deep-copies (nested mutation doesn't leak)", %{cwd: cwd} do
    write_ext(cwd, "clone.js", """
    export default function (longpi) {
      longpi.registerTool({
        name: "cloned",
        description: "Clones then mutates the copy.",
        parameters: { type: "object", properties: {} },
        execute() {
          const original = { n: 1, list: [1, 2] };
          const copy = structuredClone(original);
          copy.list.push(3);
          return JSON.stringify({ original: original.list.length, copy: copy.list.length });
        },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert {:ok, ~s({"original":2,"copy":3})} = Host.call_tool(host, "cloned", %{})
  end

  test "atob/btoa round-trip base64", %{cwd: cwd} do
    write_ext(cwd, "b64.js", """
    export default function (longpi) {
      longpi.registerTool({
        name: "b64",
        description: "base64 round-trip",
        parameters: { type: "object", properties: {} },
        execute() {
          const encoded = btoa("hi!");
          return `${encoded} ${atob(encoded)}`;
        },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert {:ok, "aGkh hi!"} = Host.call_tool(host, "b64", %{})
  end

  test "fetch keeps binary (non-UTF-8) bodies intact via arrayBuffer()", %{cwd: cwd} do
    # 0xff/0x80 are invalid UTF-8 — a lossy conversion would corrupt them.
    port = start_http_stub(<<0xFF, 0x00, 0xFE, 0x80>>, "application/octet-stream")

    write_ext(cwd, "bin.js", """
    export default function (longpi) {
      longpi.registerTool({
        name: "grab",
        description: "Reads raw bytes.",
        parameters: { type: "object", properties: {} },
        async execute() {
          const res = await fetch("http://127.0.0.1:#{port}/");
          const bytes = new Uint8Array(await res.arrayBuffer());
          return Array.from(bytes).join(",");
        },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert {:ok, "255,0,254,128"} = Host.call_tool(host, "grab", %{})
  end

  test "fetch decodes a GBK (charset) page to readable UTF-8", %{cwd: cwd} do
    # "中文" in GBK, repeated, served as text/html;charset=gbk.
    port = start_http_stub(String.duplicate(<<0xD6, 0xD0, 0xCE, 0xC4>>, 20), "text/html; charset=gbk")

    write_ext(cwd, "cn.js", """
    export default function (longpi) {
      longpi.registerTool({
        name: "grab",
        description: "Fetches a GBK page.",
        parameters: { type: "object", properties: {} },
        async execute() {
          const res = await fetch("http://127.0.0.1:#{port}/");
          const text = await res.text();
          return text.slice(0, 4);
        },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    assert {:ok, "中文中文"} = Host.call_tool(host, "grab", %{})
  end

  test "a lifecycle event handler runs and doesn't wedge the command queue", %{cwd: cwd} do
    write_ext(cwd, "life.js", """
    export default function (longpi) {
      let started = 0;
      longpi.on("turn_start", () => { started++; });
      longpi.registerTool({
        name: "count",
        description: "Reports how many turn_start events fired.",
        parameters: { type: "object", properties: {} },
        execute() { return String(started); },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)
    # Ensure the extension is loaded before firing events at it.
    _ = Host.tool_specs(host)

    Host.fire_event(host, "turn_start", %{})
    Host.fire_event(host, "turn_start", %{})

    # Casts are mailbox-ordered before the following call, so both events are
    # processed first; the call proves the queue is still live afterward.
    assert {:ok, "2"} = Host.call_tool(host, "count", %{})
  end

  # Tiny one-shot HTTP server: accept one connection, return a fixed body.
  defp start_http_stub(body, content_type \\ "application/json") do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    Task.start(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 10_000)
      {:ok, _request} = :gen_tcp.recv(sock, 0, 5_000)

      response =
        "HTTP/1.1 200 OK\r\ncontent-type: #{content_type}\r\n" <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body

      :gen_tcp.send(sock, response)
      :gen_tcp.close(sock)
      :gen_tcp.close(listen)
    end)

    port
  end
end
