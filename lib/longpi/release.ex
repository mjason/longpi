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

  defp load_app do
    Application.load(@app)
  end
end
