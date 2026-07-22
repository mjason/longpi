defmodule Longpi.Accounts.PasswordKickTest do
  # Changing a password must drop the user's live sockets, not just revoke
  # tokens — otherwise already-connected tabs keep running until they reconnect.
  use Longpi.DataCase, async: false

  alias Longpi.Accounts.User

  defp seed(email, password) do
    User
    |> Ash.Changeset.for_create(:seed_user, %{email: email, password: password})
    |> Ash.create!(authorize?: false)
  end

  defp email, do: "kick-#{System.unique_integer([:positive])}@test.dev"

  test "admin password reset (seed_user upsert) disconnects the user's sockets" do
    address = email()
    user = seed(address, "password123")

    LongpiWeb.Endpoint.subscribe("user_socket:#{user.id}")
    # Same email again = reset password.
    _ = seed(address, "newpassword456")

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 1_000
  end

  test "change_password disconnects the user's sockets" do
    user = seed(email(), "password123")

    LongpiWeb.Endpoint.subscribe("user_socket:#{user.id}")

    user
    |> Ash.Changeset.for_update(:change_password, %{
      current_password: "password123",
      password: "brandnewpass1",
      password_confirmation: "brandnewpass1"
    })
    |> Ash.update!(authorize?: false)

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 1_000
  end
end
