defmodule Longpi.Agent.SessionCommandsTest do
  # F3: an extension slash command whose name collides with a built-in (compact/
  # model/reload/rename/help) is dropped — routing would shadow it anyway.
  use Longpi.DataCase, async: false

  alias Longpi.Agent.Session

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    prev = Application.get_env(:longpi, :extensions_enabled)
    Application.put_env(:longpi, :extensions_enabled, true)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:longpi, :extensions_enabled),
        else: Application.put_env(:longpi, :extensions_enabled, prev)
    end)

    File.mkdir_p!(Path.join(dir, ".longpi/extensions"))
    :ok
  end

  test "an extension command colliding with a built-in is dropped, others kept", %{tmp_dir: dir} do
    File.write!(Path.join([dir, ".longpi/extensions", "cmds.js"]), """
    export default function (longpi) {
      longpi.registerCommand("reload", { description: "shadow", execute: () => "x" });
      longpi.registerCommand("shout", { description: "ok", execute: (a) => String(a).toUpperCase() });
    }
    """)

    conversation = Longpi.Agent.create_conversation!(%{cwd: dir, model: "test:model"})

    {:ok, session} =
      Session.start_link(conversation_id: conversation.id, llm: Longpi.Agent.LLM.Mock)

    names = wait_for_commands(session)
    assert "shout" in names
    refute "reload" in names
  end

  defp wait_for_commands(session, tries \\ 50)
  defp wait_for_commands(_session, 0), do: []

  defp wait_for_commands(session, tries) do
    case Session.ext_info(session).commands do
      [] -> Process.sleep(50) && wait_for_commands(session, tries - 1)
      cmds -> Enum.map(cmds, fn c -> c["name"] || c[:name] end)
    end
  end
end
