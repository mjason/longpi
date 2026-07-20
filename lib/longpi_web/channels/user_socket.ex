defmodule LongpiWeb.UserSocket do
  use Phoenix.Socket

  channel "conversation:*", LongpiWeb.ConversationChannel

  # TODO(auth): verify a session token here before multi-user exposure.
  # v1 runs single-user on localhost.
  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
