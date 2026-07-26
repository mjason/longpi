defmodule LongpiWeb.Plugs.DevGzip do
  @moduledoc """
  On-the-fly gzip for the dev asset bundle.

  In prod `phx.digest` pre-compresses assets and `Plug.Static gzip: true`
  serves the `.gz`. In dev nothing is pre-compressed, and `Plug.Static` uses
  sendfile (which Bandit can't compress), so the browser downloads the full
  ~3.5 MB `index.js` uncompressed — painful over LAN / on a phone.

  This plug sits BEFORE `Plug.Static`: for a gzip-capable request to a
  compressible asset it serves a gzipped copy from an ETS cache (keyed by
  path + mtime, so a rebuild invalidates it) and halts. Everything else
  falls through to `Plug.Static` untouched. Dev-only — never plugged in prod.
  """

  import Plug.Conn
  require Logger

  @table :longpi_dev_gzip_cache
  @compressible ~w(.js .css .map .json .svg)

  def init(opts), do: opts

  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["GET", "HEAD"] do
    with true <- accepts_gzip?(conn),
         path when is_binary(path) <- asset_file(conn),
         {:ok, %{type: :regular, mtime: mtime, size: size}} <- File.stat(path, time: :posix),
         # Don't bother compressing tiny files — the round-trip isn't worth it.
         true <- size > 4_096,
         {:ok, gzipped} <- fetch(path, mtime) do
      conn
      |> put_resp_header("content-encoding", "gzip")
      |> put_resp_header("vary", "accept-encoding")
      |> put_resp_header("content-type", content_type(path))
      |> put_resp_header("cache-control", "public")
      |> send_resp(200, gzipped)
      |> halt()
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp accepts_gzip?(conn) do
    conn |> get_req_header("accept-encoding") |> Enum.any?(&String.contains?(&1, "gzip"))
  end

  # Only our own asset bundle, and only compressible types.
  defp asset_file(conn) do
    with "/assets/" <> _ <- conn.request_path,
         true <- Path.extname(conn.request_path) in @compressible do
      Path.join(:code.priv_dir(:longpi), "static" <> conn.request_path)
    else
      _ -> nil
    end
  end

  # Cache the gzipped bytes keyed by {path, mtime}: a rebuild changes mtime and
  # misses, so stale bytes are never served.
  defp fetch(path, mtime) do
    ensure_table()

    case :ets.lookup(@table, path) do
      [{^path, ^mtime, gzipped}] ->
        {:ok, gzipped}

      _ ->
        case File.read(path) do
          {:ok, raw} ->
            gzipped = :zlib.gzip(raw)
            :ets.insert(@table, {path, mtime, gzipped})
            {:ok, gzipped}

          error ->
            error
        end
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end
  rescue
    # A racing creation from another request — the table exists, that's fine.
    ArgumentError -> :ok
  end

  defp content_type(path) do
    case Path.extname(path) do
      ".js" -> "text/javascript"
      ".css" -> "text/css"
      ".map" -> "application/json"
      ".json" -> "application/json"
      ".svg" -> "image/svg+xml"
      _ -> "application/octet-stream"
    end
  end
end
