defmodule LongpiWeb.ConfigController do
  @moduledoc """
  Read-only config the admin UI needs but that isn't a plain resource: the
  built-in tool catalog and the default system prompt (so the editor can show
  the real default instead of an empty box).
  """

  use LongpiWeb, :controller

  def tool_catalog(conn, _params) do
    json(conn, %{tools: Longpi.Agent.Prompts.tool_catalog()})
  end

  def defaults(conn, _params) do
    json(conn, %{
      system_prompt: Longpi.Agent.SystemPrompt.default_template(),
      tools: Longpi.Agent.Prompts.tool_catalog()
    })
  end

  def discover_models(conn, %{"provider" => provider}) do
    case Longpi.Agent.ModelDiscovery.list(provider) do
      {:ok, models} -> json(conn, %{models: models})
      {:error, message} -> conn |> put_status(422) |> json(%{error: message})
    end
  end

  def sessions(conn, _params) do
    json(conn, %{sessions: Longpi.Agent.Sessions.list_active()})
  end

  def stop_session(conn, %{"conversation_id" => id}) do
    Longpi.Agent.Sessions.stop(id)
    json(conn, %{ok: true})
  end

  def extensions(conn, _params) do
    json(conn, %{
      dir: Longpi.Extensions.global_dir(),
      extensions: Longpi.Extensions.list_global(),
      packages: Longpi.Extensions.read_packages()
    })
  end

  def save_packages(conn, %{"packages" => packages}) when is_map(packages) do
    case Longpi.Extensions.write_packages(packages) do
      :ok -> json(conn, %{ok: true})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end
end
