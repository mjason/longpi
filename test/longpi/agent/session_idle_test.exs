defmodule Longpi.Agent.SessionIdleTest do
  # Idle-reaping: a persisted session with no connected watcher recycles itself
  # after the idle timeout; watched or non-persisted sessions never do.
  use Longpi.DataCase, async: false

  alias Longpi.Agent.Session

  @moduletag :tmp_dir

  setup do
    prev = Application.get_env(:longpi, :session_idle_timeout_ms)
    # A short timeout so the test doesn't wait; restored afterward.
    Application.put_env(:longpi, :session_idle_timeout_ms, 80)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:longpi, :session_idle_timeout_ms, prev),
        else: Application.delete_env(:longpi, :session_idle_timeout_ms)
    end)

    :ok
  end

  defp start(dir) do
    conversation = Longpi.Agent.create_conversation!(%{cwd: dir, model: "test:model"})
    {:ok, session} = Session.start_link(conversation_id: conversation.id, llm: Longpi.Agent.LLM.Mock)
    session
  end

  test "an idle, unwatched, persisted session reaps itself", %{tmp_dir: dir} do
    session = start(dir)
    ref = Process.monitor(session)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2_000
  end

  test "a watched session is not reaped", %{tmp_dir: dir} do
    session = start(dir)
    :ok = Session.watch(session, self())
    ref = Process.monitor(session)
    refute_receive {:DOWN, ^ref, :process, ^session, _}, 400
    assert Process.alive?(session)
  end

  test "a session reaps once its last watcher disconnects", %{tmp_dir: dir} do
    session = start(dir)

    watcher =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    :ok = Session.watch(session, watcher)
    ref = Process.monitor(session)
    refute_receive {:DOWN, ^ref, :process, ^session, _}, 300

    send(watcher, :stop)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2_000
  end

  test "a non-persisted session (no conversation_id) is never reaped", %{tmp_dir: _dir} do
    {:ok, session} = Session.start_link(llm: Longpi.Agent.LLM.Mock)
    ref = Process.monitor(session)
    refute_receive {:DOWN, ^ref, :process, ^session, _}, 400
  end
end
