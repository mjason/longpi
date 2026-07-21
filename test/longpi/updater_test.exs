defmodule Longpi.UpdaterTest do
  use ExUnit.Case, async: false

  alias Longpi.Updater

  # Stub source modules so `check/0` never touches the network.
  defmodule NewerSource do
    @behaviour Longpi.Updater.Source
    @impl true
    def latest_stable do
      {:ok, %{"tag_name" => "v999.0.0", "html_url" => "http://notes", "assets" => []}}
    end
  end

  defmodule SameSource do
    @behaviour Longpi.Updater.Source
    @impl true
    def latest_stable do
      {:ok, %{"tag_name" => "v#{Longpi.Updater.current_version()}", "assets" => []}}
    end
  end

  defmodule DownSource do
    @behaviour Longpi.Updater.Source
    @impl true
    def latest_stable, do: {:error, "could not reach GitHub"}
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:longpi, :updater_source)
      Application.delete_env(:longpi, :release_root)
    end)
  end

  describe "enabled?/0" do
    test "false without a release_root (a dev/mix run)" do
      Application.delete_env(:longpi, :release_root)
      refute Updater.enabled?()
    end

    test "true once a release_root is configured" do
      Application.put_env(:longpi, :release_root, "/tmp/longpi-install")
      assert Updater.enabled?()
    end
  end

  describe "check/0" do
    test "reports an available update when GitHub is newer and updater is enabled" do
      Application.put_env(:longpi, :updater_source, NewerSource)
      Application.put_env(:longpi, :release_root, "/tmp/longpi-install")

      assert {:ok, info} = Updater.check()
      assert info.enabled
      assert info.latest == "999.0.0"
      assert info.tag == "v999.0.0"
      assert info.update_available
      assert info.notes_url == "http://notes"
      assert info.current == Updater.current_version()
    end

    test "no update offered when disabled, even if GitHub is newer" do
      Application.put_env(:longpi, :updater_source, NewerSource)
      Application.delete_env(:longpi, :release_root)

      assert {:ok, info} = Updater.check()
      refute info.enabled
      refute info.update_available
    end

    test "no update when already on the latest version" do
      Application.put_env(:longpi, :updater_source, SameSource)
      Application.put_env(:longpi, :release_root, "/tmp/longpi-install")

      assert {:ok, info} = Updater.check()
      refute info.update_available
    end

    test "propagates a source error" do
      Application.put_env(:longpi, :updater_source, DownSource)
      assert {:error, "could not reach GitHub"} = Updater.check()
    end
  end

  describe "apply_latest/0" do
    test "refuses to upgrade when not running from an installed release" do
      Application.put_env(:longpi, :updater_source, NewerSource)
      Application.delete_env(:longpi, :release_root)

      assert {:error, msg} = Updater.apply_latest()
      assert msg =~ "only available on installed releases"
    end
  end
end
