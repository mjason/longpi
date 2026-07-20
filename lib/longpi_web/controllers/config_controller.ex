defmodule LongpiWeb.ConfigController do
  @moduledoc """
  Read-only config the admin UI needs but that isn't a plain resource - the
  built-in tool catalog (names + default and effective descriptions).
  """

  use LongpiWeb, :controller

  def tool_catalog(conn, _params) do
    json(conn, %{tools: Longpi.Agent.Prompts.tool_catalog()})
  end
end
