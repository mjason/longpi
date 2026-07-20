defmodule LongpiWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix channels.

  Channels drive agent sessions that access the database from their own
  processes, so use `async: false` to get a shared SQL sandbox.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import LongpiWeb.ChannelCase

      @endpoint LongpiWeb.Endpoint
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Longpi.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
