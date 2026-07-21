defmodule Longpi.Agent.Sessions do
  @moduledoc """
  Process registry for running agent sessions, one per conversation.

  `ensure_started/2` is the get-or-start entry point the web layer uses:
  joining a Phoenix Channel for a conversation resolves to the same session
  process from any browser tab.
  """

  alias Longpi.Agent.Session

  @registry Longpi.Agent.SessionRegistry
  @supervisor Longpi.Agent.SessionSupervisor

  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(conversation_id, opts \\ []) do
    case whereis(conversation_id) do
      nil -> start(conversation_id, opts)
      pid -> {:ok, pid}
    end
  end

  @doc "Snapshots of every running session, for the management dashboard."
  @spec list_active() :: [map()]
  def list_active do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {conversation_id, pid} ->
      pid |> Session.summary() |> Map.put(:conversation_id, conversation_id)
    end)
  rescue
    _ -> []
  end

  @spec whereis(String.t()) :: pid() | nil
  def whereis(conversation_id) do
    case Registry.lookup(@registry, conversation_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @spec stop(String.t()) :: :ok
  def stop(conversation_id) do
    case whereis(conversation_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  defp start(conversation_id, opts) do
    opts = Keyword.merge(opts, conversation_id: conversation_id, name: via(conversation_id))

    case DynamicSupervisor.start_child(@supervisor, {Session, opts}) do
      {:ok, pid} -> {:ok, pid}
      # Lost the race against a concurrent ensure_started - that's still a win.
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  defp via(conversation_id), do: {:via, Registry, {@registry, conversation_id}}
end
