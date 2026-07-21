defmodule Longpi.Extensions.HostSecretsTest do
  # Exercises the real Bun host reading a DB-stored secret from process.env.
  # Needs `bun` on PATH (tagged :extensions) and DB access (DataCase, async:
  # false → shared sandbox so the Host process sees the seeded secret).
  use Longpi.DataCase, async: false

  @moduletag :extensions
  @moduletag :tmp_dir

  alias Longpi.Extensions
  alias Longpi.Extensions.Host

  test "an extension reads a DB secret via process.env, and /reload applies changes",
       %{tmp_dir: cwd} do
    File.mkdir_p!(Path.join(cwd, ".longpi/extensions"))

    File.write!(Path.join([cwd, ".longpi/extensions", "echo.ts"]), """
    export default function (pi) {
      pi.registerTool({
        name: "echo_secret",
        description: "Returns the injected secret.",
        parameters: { type: "object", properties: {} },
        execute() { return process.env.MY_SECRET ?? "(unset)"; },
      });
    }
    """)

    :ok = Extensions.put_secret("MY_SECRET", "from-db")

    {:ok, host} = Host.start_for(cwd)
    assert {:ok, "from-db"} = Host.call_tool(host, "echo_secret", %{})

    # Changing the secret and reloading applies the new value...
    :ok = Extensions.put_secret("MY_SECRET", "changed")
    Host.reload(host)
    assert {:ok, "changed"} = Host.call_tool(host, "echo_secret", %{})

    # ...and deleting it removes the var on the next reload.
    :ok = Extensions.delete_secret("MY_SECRET")
    Host.reload(host)
    assert {:ok, "(unset)"} = Host.call_tool(host, "echo_secret", %{})
  end
end
