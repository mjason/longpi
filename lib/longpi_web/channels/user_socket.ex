defmodule LongpiWeb.UserSocket do
  use Phoenix.Socket

  channel "conversation:*", LongpiWeb.ConversationChannel

  # When auth is enabled, the socket requires the bearer token the SPA layout
  # embeds for the signed-in user (revoked with the session on sign-out).
  # Auth off (the default localhost/LAN install) connects anonymously.
  @impl true
  def connect(params, socket, _connect_info) do
    if Longpi.Auth.enabled?() do
      case Longpi.Auth.verify_bearer_token(params["token"]) do
        {:ok, user} -> {:ok, assign(socket, :user_id, user.id)}
        :error -> :error
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def id(%{assigns: %{user_id: user_id}}), do: "user_socket:#{user_id}"
  def id(_socket), do: nil
end
