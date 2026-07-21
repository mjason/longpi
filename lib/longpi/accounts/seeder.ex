defmodule Longpi.Accounts.Seeder do
  @moduledoc """
  Boot-time account bootstrap — there is no self-registration.

  Parses `LONGPI_USERS` (or config.jsonc `auth.users`): `email:password`
  pairs separated by commas, semicolons or newlines. Each pair creates the account if it doesn't exist yet, so the
  plaintext line can (and should) be removed after first boot. Set
  `LONGPI_USERS_RESET=true` for one boot to force the listed passwords.

  Runs synchronously in the supervision tree, after the migrator and before
  the endpoint, so `verify_accounts_exist!/0` can refuse to boot an
  auth-enabled server that nobody could sign in to.
  """

  require Logger

  alias Longpi.Accounts.User

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :transient, type: :worker}
  end

  @doc false
  def start_link do
    run()
    verify_accounts_exist!()
    :ignore
  end

  @doc "Seeds accounts from the configured `bootstrap_users` string."
  def run do
    reset? = Application.get_env(:longpi, :bootstrap_users_reset, false)
    pairs = parse(Application.get_env(:longpi, :bootstrap_users) || "")

    for {email, password} <- pairs do
      seed(email, password, reset?)
    end

    # A password sitting in config.jsonc is a standing leak — it has done its
    # job once the account exists. (Env vars don't persist, so no nag there.)
    if pairs != [] and Application.get_env(:longpi, :bootstrap_users_source) == :config do
      Logger.warning(
        "accounts: remove \"users\" from config.jsonc's auth block — the account(s) are stored " <>
          "now, and the plaintext password should not stay on disk. " <>
          "Use bin/longpi eval 'Longpi.Release.add_user(...)' for future changes."
      )
    end

    :ok
  end

  @doc ~S|Parses "a@b.c:pw1,d@e.f:pw2" into [{email, password}] pairs.|
  def parse(spec) when is_binary(spec) do
    spec
    |> String.split(~r/[,;\n]/, trim: true)
    |> Enum.flat_map(fn pair ->
      case String.split(String.trim(pair), ":", parts: 2) do
        [email, password] when email != "" and password != "" ->
          # Trim both halves: "a@b.c: pw" is a formatting space, not part of
          # the password (a password that needs colons still works — only the
          # first ":" splits).
          [{String.trim(email), String.trim(password)}]

        _ ->
          []
      end
    end)
  end

  def parse(_spec), do: []

  @doc "Raises when auth is enabled but no account exists (nobody could sign in)."
  def verify_accounts_exist! do
    if Longpi.Auth.enabled?() and Ash.count!(User, authorize?: false) == 0 do
      raise """
      auth is enabled but no user accounts exist — nobody could sign in.

      If you DID set users, check the log lines above: a seed failure (for
      example a password shorter than 8 characters) is reported there.

      Bootstrap an account for the next boot, e.g.:

          LONGPI_USERS="admin@example.com:changeme123"

      or in ~/.config/longpi/config.jsonc:

          "auth": { "enabled": true, "users": "admin@example.com:changeme123" }
      """
    end

    :ok
  end

  defp seed(email, password, reset?) do
    exists? = user_exists?(email)

    cond do
      not exists? -> upsert(email, password, "created")
      reset? -> upsert(email, password, "password reset")
      true -> :ok
    end
  end

  defp user_exists?(email) do
    case User |> Ash.Query.for_read(:get_by_email, %{email: email}) |> Ash.read_one(authorize?: false) do
      {:ok, %User{}} -> true
      _ -> false
    end
  end

  defp upsert(email, password, verb) do
    case User
         |> Ash.Changeset.for_create(:seed_user, %{email: email, password: password})
         |> Ash.create(authorize?: false) do
      {:ok, _user} ->
        Logger.info("accounts: #{verb} #{email}")

      {:error, error} ->
        Logger.error("accounts: could not seed #{email}: #{Exception.message(error)}")
    end
  end
end
