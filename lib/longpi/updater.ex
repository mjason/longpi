defmodule Longpi.Updater do
  @moduledoc """
  In-app self-upgrade against GitHub releases.

  Only active when running from an installed release — `release_root` points at
  the `versions/<tag>` + `current` tree that install.sh lays out. Applying an
  update downloads the new tarball next to the current one, atomically
  re-points the `current` symlink and asks systemd to restart the user service.
  The service migrates the database (via its `ExecStartPre`) before the new
  version boots; in-flight requests just reconnect once it's back.
  """
  require Logger

  alias Longpi.Updater.Release

  def repo, do: Application.get_env(:longpi, :update_repo) || "mjason/longpi"

  def service_name, do: Application.get_env(:longpi, :service_name) || "longpi"

  @doc """
  The install root (`~/.local/longpi`) when running from a release, else nil.

  Derived from `RELEASE_ROOT` (`.../longpi/versions/<tag>`): the segment before
  `/versions/` is the root. A dev/`mix` run has no such env, so it stays nil and
  the updater is disabled.
  """
  def release_root do
    case Application.get_env(:longpi, :release_root) do
      root when is_binary(root) and root != "" -> root
      _ -> nil
    end
  end

  def enabled?, do: release_root() != nil

  def current_version, do: :longpi |> Application.spec(:vsn) |> to_string()

  @doc "Latest release info vs the running version."
  def check do
    with {:ok, release} <- fetch_latest() do
      tag = release["tag_name"] || ""
      latest = String.trim_leading(tag, "v")

      {:ok,
       %{
         enabled: enabled?(),
         current: current_version(),
         latest: latest,
         tag: tag,
         update_available: enabled?() and Release.newer?(latest, current_version()),
         notes_url: release["html_url"]
       }}
    end
  end

  @doc "Download the latest release, switch `current` and restart the daemon."
  def apply_latest do
    with :ok <- ensure_enabled(),
         {:ok, release} <- fetch_latest(),
         tag = release["tag_name"],
         :ok <- validate_tag(tag),
         :ok <- ensure_newer(tag),
         {:ok, url} <- Release.asset_url(release),
         :ok <- install_version(tag, url, release),
         :ok <- switch_current(tag) do
      Logger.info("updater: switched to #{tag}, requesting restart")
      restart()
      {:ok, %{updated_to: tag}}
    end
  end

  defp ensure_enabled do
    if enabled?(), do: :ok, else: {:error, "updater is only available on installed releases"}
  end

  defp ensure_newer(tag) do
    if Release.newer?(String.trim_leading(tag || "", "v"), current_version()),
      do: :ok,
      else: {:error, "already up to date (#{current_version()})"}
  end

  defp source, do: Application.get_env(:longpi, :updater_source, Longpi.Updater.GitHub)

  defp fetch_latest, do: source().latest_stable()

  # The tag becomes a filesystem path component; GitHub lets a compromised
  # repo publish an arbitrary tag_name, so refuse anything path-like.
  defp validate_tag(tag) do
    if is_binary(tag) and tag =~ ~r/^v?[\w][\w.\-]*$/,
      do: :ok,
      else: {:error, "refusing suspicious release tag: #{inspect(tag)}"}
  end

  defp install_version(tag, url, release) do
    dest = Path.join([release_root(), "versions", tag])

    if File.exists?(Path.join(dest, "bin/longpi")) do
      :ok
    else
      # Inside release_root (user-owned), unique name — never a predictable
      # path in world-writable /tmp where a symlink could redirect the write.
      tarball =
        Path.join(
          release_root(),
          ".longpi-#{tag}-#{:erlang.unique_integer([:positive])}.tar.gz.part"
        )

      try do
        with :ok <- download(url, tarball),
             :ok <- verify_checksum(tarball, release) do
          File.mkdir_p!(dest)

          case System.cmd("tar", ["-xzf", tarball, "-C", dest], stderr_to_stdout: true) do
            {_, 0} ->
              :ok

            {out, _} ->
              File.rm_rf(dest)
              {:error, "unpack failed: #{String.slice(out, 0, 200)}"}
          end
        end
      after
        File.rm(tarball)
      end
    end
  end

  # The release workflow publishes `<asset>.sha256` (sha256sum output) next to
  # every tarball; a download that doesn't match it never gets unpacked.
  defp verify_checksum(tarball, release) do
    with {:ok, url} <- Release.checksum_url(release),
         {:ok, %{status: 200, body: body}} <- Req.get(url, retry: false),
         [expected | _] <- body |> to_string() |> String.split() do
      actual =
        tarball
        |> File.stream!(2_048 * 1_024)
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(actual, String.downcase(expected)),
        do: :ok,
        else: {:error, "checksum mismatch — expected #{expected}, got #{actual}"}
    else
      {:error, reason} -> {:error, "checksum unavailable: #{inspect(reason)}"}
      other -> {:error, "checksum unavailable: #{inspect(other)}"}
    end
  end

  defp download(url, to) do
    Logger.info("updater: downloading #{url}")

    case Req.get(url, into: File.stream!(to), retry: false, receive_timeout: 300_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, "download failed with #{status}"}
      {:error, reason} -> {:error, "download failed: #{Exception.message(reason)}"}
    end
  end

  # rename(2) over the existing symlink makes the switch atomic.
  defp switch_current(tag) do
    root = release_root()
    fresh = Path.join(root, ".current.new")
    File.rm(fresh)

    with :ok <- File.ln_s(Path.join([root, "versions", tag]), fresh),
         :ok <- File.rename(fresh, Path.join(root, "current")) do
      :ok
    else
      {:error, reason} -> {:error, "could not switch current: #{inspect(reason)}"}
    end
  end

  # `--no-block` lets this HTTP response return before systemd tears the VM down.
  defp restart do
    System.cmd("systemctl", ["--user", "restart", "--no-block", service_name()],
      stderr_to_stdout: true
    )
  end
end
