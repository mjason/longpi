defmodule LongpiWeb.UserSocket do
  use Phoenix.Socket

  channel "conversation:*", LongpiWeb.ConversationChannel

  # When auth is enabled, the socket requires either the signed-in session's
  # bearer token (revoked with the session on sign-out) or the static embed
  # token a host app passes to its iframe. Auth off (the default localhost/LAN
  # install) connects anonymously.
  @impl true
  def connect(params, socket, _connect_info) do
    cond do
      not Longpi.Auth.enabled?() ->
        {:ok, socket}

      Longpi.Auth.verify_embed_token(params["token"]) ->
        {:ok, socket}

      true ->
        case Longpi.Auth.verify_bearer_token(params["token"]) do
          {:ok, user} -> {:ok, assign(socket, :user_id, user.id)}
          :error -> :error
        end
    end
  end

  @impl true
  def id(%{assigns: %{user_id: user_id}}), do: "user_socket:#{user_id}"
  def id(_socket), do: nil

  @doc """
  Drops every live socket belonging to a user, so a password change takes
  effect immediately instead of leaving already-connected tabs authenticated.
  Best-effort and boot-safe: a no-op when the endpoint isn't running yet (e.g.
  during boot-time user seeding).
  """
  @spec disconnect(term()) :: :ok
  def disconnect(user_id) do
    if Process.whereis(LongpiWeb.Endpoint) do
      LongpiWeb.Endpoint.broadcast("user_socket:#{user_id}", "disconnect", %{})
    end

    :ok
  end
end
