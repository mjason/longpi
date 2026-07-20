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
end
