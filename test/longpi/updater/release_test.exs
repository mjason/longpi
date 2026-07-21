defmodule Longpi.Updater.ReleaseTest do
  use ExUnit.Case, async: true

  alias Longpi.Updater.Release

  describe "platform/2" do
    test "linux x86_64" do
      assert Release.platform({:unix, :linux}, ~c"x86_64-pc-linux-gnu") == "linux-x86_64"
    end

    test "non-x86 linux is unsupported" do
      assert Release.platform({:unix, :linux}, ~c"aarch64-unknown-linux-gnu") == "unsupported"
    end

    test "other OSes are unsupported" do
      assert Release.platform({:unix, :darwin}, ~c"aarch64-apple-darwin") == "unsupported"
      assert Release.platform({:win32, :nt}, ~c"win32") == "unsupported"
    end
  end

  describe "asset_suffix/1" do
    test "appends the tarball extension" do
      assert Release.asset_suffix("linux-x86_64") == "linux-x86_64.tar.gz"
    end
  end

  describe "newer?/2" do
    test "true only when latest is strictly newer" do
      assert Release.newer?("0.1.2", "0.1.1")
      assert Release.newer?("1.0.0", "0.9.9")
    end

    test "false when equal or older" do
      refute Release.newer?("0.1.1", "0.1.1")
      refute Release.newer?("0.1.0", "0.1.1")
    end

    test "false for unparseable versions" do
      refute Release.newer?("garbage", "0.1.1")
      refute Release.newer?("0.1.2", "not-a-version")
      refute Release.newer?("v0.1.2", "0.1.1")
    end
  end

  describe "stable_release?/1" do
    test "true for a plain vX.Y.Z release" do
      assert Release.stable_release?(%{"tag_name" => "v0.1.2", "draft" => false, "prerelease" => false})
    end

    test "false for drafts and prereleases" do
      refute Release.stable_release?(%{"tag_name" => "v0.1.2", "draft" => true})
      refute Release.stable_release?(%{"tag_name" => "v0.1.2", "prerelease" => true})
    end

    test "false for non-version or non-string tags" do
      refute Release.stable_release?(%{"tag_name" => "nightly"})
      refute Release.stable_release?(%{"tag_name" => nil})
      refute Release.stable_release?(%{})
    end
  end

  describe "asset_url/2" do
    test "finds the matching platform tarball" do
      release = %{
        "tag_name" => "v0.1.2",
        "assets" => [
          %{"name" => "longpi-v0.1.2-linux-x86_64.tar.gz.sha256", "browser_download_url" => "http://x/sha"},
          %{"name" => "longpi-v0.1.2-linux-x86_64.tar.gz", "browser_download_url" => "http://x/tar"}
        ]
      }

      assert Release.asset_url(release, "linux-x86_64") == {:ok, "http://x/tar"}
    end

    test "errors when no matching asset" do
      release = %{"tag_name" => "v0.1.2", "assets" => [%{"name" => "notes.txt"}]}
      assert {:error, msg} = Release.asset_url(release, "linux-x86_64")
      assert msg =~ "no linux-x86_64.tar.gz asset"
    end

    test "errors on malformed payloads" do
      assert {:error, _} = Release.asset_url(%{"tag_name" => "v0.1.2"}, "linux-x86_64")
      assert {:error, _} = Release.asset_url("nope", "linux-x86_64")
    end
  end
end
