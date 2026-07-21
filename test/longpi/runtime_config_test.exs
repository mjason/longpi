defmodule Longpi.RuntimeConfigTest do
  # Not async: mutates process env and the filesystem.
  use ExUnit.Case, async: false

  alias Longpi.{Jsonc, RuntimeConfig}

  describe "Jsonc.strip/1" do
    test "removes line and block comments" do
      assert Jsonc.strip(~s|{ // hi\n "a": 1, /* b */ "c": 2 }|) |> Jason.decode!() ==
               %{"a" => 1, "c" => 2}
    end

    test "preserves comment-like sequences inside strings" do
      assert Jsonc.strip(~s|{ "url": "http://x//y", "star": "a/*b*/c" }|) |> Jason.decode!() ==
               %{"url" => "http://x//y", "star" => "a/*b*/c"}
    end

    test "honors escaped quotes in strings" do
      assert Jsonc.strip(~s|{ "q": "a\\"//b" }|) |> Jason.decode!() == %{"q" => ~s|a"//b|}
    end
  end

  describe "get/get_int/get_bool — file is authoritative" do
    test "the config file value wins over defaults" do
      cfg = %{"port" => 4321, "server" => true, "host" => "example.test"}
      assert RuntimeConfig.get_int(cfg, ["PORT"], "port", 4000) == 4321
      assert RuntimeConfig.get_bool(cfg, [], "server", false) == true
      assert RuntimeConfig.get(cfg, [], "host", "localhost") == "example.test"
    end

    test "defaults apply when the key is absent" do
      assert RuntimeConfig.get_int(%{}, ["ABSENT_VAR"], "port", 4000) == 4000
      assert RuntimeConfig.get_bool(%{}, [], "checkOrigin", false) == false
      assert RuntimeConfig.get(%{}, [], "host", "localhost") == "localhost"
    end

    test "env vars are consulted only when NO config file exists (cfg == %{})" do
      System.put_env("LONGPI_TEST_PORT", "9001")
      on_exit(fn -> System.delete_env("LONGPI_TEST_PORT") end)

      # empty cfg -> env applies
      assert RuntimeConfig.get_int(%{}, ["LONGPI_TEST_PORT"], "port", 4000) == 9001
      # non-empty cfg -> env ignored, file/default wins
      assert RuntimeConfig.get_int(%{"host" => "x"}, ["LONGPI_TEST_PORT"], "port", 4000) == 4000
    end

    test "get_int raises on non-integer garbage" do
      assert_raise RuntimeError, fn ->
        RuntimeConfig.get_int(%{"port" => "not-a-number"}, [], "port", 4000)
      end
    end
  end

  describe "data_dir/1" do
    test "uses the configured dataDir, expanded" do
      assert RuntimeConfig.data_dir(%{"dataDir" => "/var/lib/longpi"}) == "/var/lib/longpi"
    end

    test "falls back to XDG_DATA_HOME/longpi" do
      System.put_env("XDG_DATA_HOME", "/tmp/xdg-data-test")
      on_exit(fn -> System.delete_env("XDG_DATA_HOME") end)
      assert RuntimeConfig.data_dir(%{}) == "/tmp/xdg-data-test/longpi"
    end
  end

  describe "secret/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "longpi_rc_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      %{cfg: %{"dataDir" => dir}, dir: dir}
    end

    test "generates, persists (0600), and returns the same value on re-read", %{
      cfg: cfg,
      dir: dir
    } do
      first = RuntimeConfig.secret(cfg, [], "secretKeyBase")
      assert byte_size(first) > 40

      # stable across calls (read back, not regenerated)
      assert RuntimeConfig.secret(cfg, [], "secretKeyBase") == first

      path = Path.join(dir, "secrets.json")
      assert File.exists?(path)
      assert rem(File.stat!(path).mode, 0o1000) == 0o600
      assert Jason.decode!(File.read!(path))["secretKeyBase"] == first
    end

    test "distinct keys get distinct secrets in the same file", %{cfg: cfg} do
      a = RuntimeConfig.secret(cfg, [], "secretKeyBase")
      b = RuntimeConfig.secret(cfg, [], "tokenSigningSecret")
      assert a != b
    end
  end
end
