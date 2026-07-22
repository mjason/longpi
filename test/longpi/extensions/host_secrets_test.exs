defmodule Longpi.Extensions.HostSecretsTest do
  # The wasm host reading a DB-stored secret via process.env. DataCase +
  # async: false → shared sandbox so the Host process sees the seeded secret.
  use Longpi.DataCase, async: false

  @moduletag :tmp_dir

  alias Longpi.Extensions
  alias Longpi.Extensions.Host

  test "an extension reads a DB secret via process.env; edits apply on the next call",
       %{tmp_dir: cwd} do
    File.mkdir_p!(Path.join(cwd, ".longpi/extensions"))

    File.write!(Path.join([cwd, ".longpi/extensions", "echo.js"]), """
    export default function (longpi) {
      longpi.registerTool({
        name: "echo_secret",
        description: "Returns the injected secret.",
        parameters: { type: "object", properties: {} },
        execute() { return process.env.MY_SECRET ?? "(unset)"; },
      });
    }
    """)

    {:ok, host} = Host.start_for(cwd)

    # No secret yet.
    assert {:ok, "(unset)"} = Host.call_tool(host, "echo_secret", %{})

    # Secrets ride along on every call — no reload needed.
    :ok = Extensions.put_secret("MY_SECRET", "s3cr3t")
    assert {:ok, "s3cr3t"} = Host.call_tool(host, "echo_secret", %{})

    :ok = Extensions.put_secret("MY_SECRET", "rotated")
    assert {:ok, "rotated"} = Host.call_tool(host, "echo_secret", %{})

    # Deleted secrets disappear too.
    :ok = Extensions.delete_secret("MY_SECRET")
    assert {:ok, "(unset)"} = Host.call_tool(host, "echo_secret", %{})
  end
end
