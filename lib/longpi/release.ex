defmodule Longpi.Release do
  @moduledoc """
  Release tasks, run without Mix in a built release, e.g.

      bin/longpi eval "Longpi.Release.migrate()"

  Migrations also run automatically at boot (see `Longpi.Application`), so this
  is mainly for a belt-and-suspenders pre-start step in the service unit.
  """
  @app :longpi

  @doc "Runs all pending Ecto migrations for every configured repo."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Rolls `repo` back to migration version `version`."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  @doc """
  Creates (or resets the password of) a local account, straight into the
  database — the password never touches a config file:

      bin/longpi eval 'Longpi.Release.add_user("admin@example.com", "changeme123")'

  Used by install.sh's first-run auth setup and for later account management.
  """
  def add_user(email, password) when is_binary(email) and is_binary(password) do
    load_app()
    # Bcrypt hashing needs its NIF started; the repo needs to be running.
    {:ok, _} = Application.ensure_all_started(:bcrypt_elixir)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Longpi.Repo, fn _repo ->
        Longpi.Accounts.User
        |> Ash.Changeset.for_create(:seed_user, %{email: email, password: password})
        |> Ash.create!(authorize?: false)

        IO.puts("account ready: #{email}")
      end)

    :ok
  end

  defp load_app do
    Application.load(@app)
  end
end
