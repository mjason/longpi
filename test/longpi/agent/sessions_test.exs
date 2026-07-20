defmodule Longpi.Agent.SessionsTest do
  use Longpi.DataCase, async: false

  import Mox

  alias Longpi.Agent.Sessions

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    conversation = Longpi.Agent.create_conversation!(%{cwd: dir, model: "test:model"})
    on_exit(fn -> Sessions.stop(conversation.id) end)
    %{conversation: conversation}
  end

  test "ensure_started is idempotent per conversation", %{conversation: conversation} do
    assert {:ok, pid} = Sessions.ensure_started(conversation.id, llm: Longpi.Agent.LLM.Mock)
    assert {:ok, ^pid} = Sessions.ensure_started(conversation.id, llm: Longpi.Agent.LLM.Mock)
    assert Sessions.whereis(conversation.id) == pid
  end

  test "whereis returns nil for unknown conversations" do
    assert Sessions.whereis(Ash.UUID.generate()) == nil
  end

  test "stop terminates the session", %{conversation: conversation} do
    {:ok, pid} = Sessions.ensure_started(conversation.id, llm: Longpi.Agent.LLM.Mock)
    ref = Process.monitor(pid)

    assert :ok = Sessions.stop(conversation.id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

    # Registry unregistration is async after process death
    assert wait_until(fn -> Sessions.whereis(conversation.id) == nil end)
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    fun.() || (Process.sleep(20) && wait_until(fun, attempts - 1))
  end
end
