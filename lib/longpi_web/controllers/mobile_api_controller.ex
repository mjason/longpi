defmodule LongpiWeb.MobileApiController do
  @moduledoc """
  JSON API for the native mobile shell (SwiftUI list + WKWebView chat pages).

  The shell renders the conversation LIST natively — that's where native
  navigation pays off — and opens `/m/c/:id?token=` in a WebView per chat.
  Auth is the embed token on every request (router `:mobile_token_auth`).
  """

  use LongpiWeb, :controller

  def conversations(conn, _params) do
    conversations =
      Longpi.Agent.list_conversations!()
      |> Enum.reject(& &1.parent_id)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      |> Enum.map(fn c ->
        %{
          id: c.id,
          title: c.title,
          cwd: c.cwd,
          model: c.model,
          updated_at: c.updated_at
        }
      end)

    json(conn, %{conversations: conversations})
  end

  def create_conversation(conn, %{"cwd" => cwd} = params) when is_binary(cwd) do
    attrs = %{
      cwd: String.trim(cwd),
      model: params["model"] || default_model()
    }

    case Longpi.Agent.create_conversation(attrs) do
      {:ok, c} ->
        json(conn, %{id: c.id, title: c.title, cwd: c.cwd, model: c.model})

      {:error, error} ->
        conn |> put_status(422) |> json(%{error: Exception.message(error)})
    end
  end

  def create_conversation(conn, _params),
    do: conn |> put_status(422) |> json(%{error: "cwd is required"})

  def delete_conversation(conn, %{"id" => id}) do
    case Longpi.Agent.get_conversation(id) do
      {:ok, conversation} ->
        Longpi.Agent.destroy_conversation!(conversation)
        json(conn, %{ok: true})

      {:error, _} ->
        conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def models(conn, _params) do
    models =
      Longpi.Agent.list_enabled_models!()
      |> Enum.map(&%{spec: &1.spec, label: &1.label})

    json(conn, %{models: models, default: default_model()})
  end

  defp default_model do
    case Longpi.Agent.get_setting_by_key("default_model") do
      {:ok, %{value: value}} when is_binary(value) and value != "" -> value
      _ -> "openai:gpt-5.4"
    end
  end
end
