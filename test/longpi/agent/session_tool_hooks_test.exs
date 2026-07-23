defmodule Longpi.Agent.SessionToolHooksTest do
  # Extensions observe tool activity: the session fires "tool_call"/"tool_result"
  # events to the extension host (off the hot path, fire-and-forget).
  use Longpi.DataCase, async: false

  alias Longpi.Agent.Session

  defmodule FakeHost do
    @moduledoc false
    use GenServer

    def start_link(pid), do: GenServer.start_link(__MODULE__, pid)
    @impl true
    def init(pid), do: {:ok, pid}
    @impl true
    def handle_cast(msg, pid), do: (send(pid, {:host_cast, msg}) && {:noreply, pid})
  end

  test "tool_call and tool_result turn events are forwarded to the extension host" do
    {:ok, host} = FakeHost.start_link(self())
    {:ok, session} = Session.start_link(llm: Longpi.Agent.LLM.Mock)
    :sys.replace_state(session, fn state -> %{state | ext_host: host} end)

    call = %{id: "c1", name: "read", args: %{"path" => "x.ex"}}

    send(session, {:turn_event, {:tool_call, call}})
    assert_receive {:host_cast, {:event, "tool_call", %{name: "read", id: "c1"}}}, 1_000

    send(session, {:turn_event, {:tool_result, %{call: call, content: "ok", error?: false}}})

    assert_receive {:host_cast, {:event, "tool_result", %{name: "read", content: "ok", error: false}}},
                   1_000
  end
end
