defmodule Longpi.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LongpiWeb.Telemetry,
      Longpi.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:longpi, :ecto_repos), skip: skip_migrations?()},
      # Bootstraps accounts from LONGPI_USERS and refuses to boot an
      # auth-enabled server with zero users. Synchronous, before the endpoint.
      Longpi.Accounts.Seeder,
      {DNSCluster, query: Application.get_env(:longpi, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Longpi.PubSub},
      {DynamicSupervisor, name: Longpi.Shell.CommandSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Longpi.Agent.TaskSupervisor},
      {Registry, keys: :unique, name: Longpi.Agent.SessionRegistry},
      {DynamicSupervisor, name: Longpi.Agent.SessionSupervisor, strategy: :one_for_one},
      # Cron-scheduled tasks: ticks every minute, fires due tasks into their
      # conversations. After the session supervisor (it starts sessions).
      Longpi.Agent.Scheduler,
      # Brute-force throttle for the mobile login endpoint (per-IP ETS).
      LongpiWeb.LoginThrottle,
      # Start a worker by calling: Longpi.Worker.start_link(arg)
      # {Longpi.Worker, arg},
      # Start to serve requests, typically the last entry
      LongpiWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :longpi]}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Longpi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LongpiWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
