defmodule Longpi.Agent.PermissionsTest do
  use Longpi.DataCase, async: false

  alias Longpi.Agent.Permissions

  test "defaults to :auto" do
    assert Permissions.level() == :auto
  end

  test "auto: reads and workspace edits run, bash asks" do
    Permissions.put_level(:auto)
    assert Permissions.mode("read") == :allow
    assert Permissions.mode("write") == :allow
    assert Permissions.mode("edit") == :allow
    assert Permissions.mode("bash") == :ask
  end

  test "read_only: only reads run, everything else asks" do
    Permissions.put_level(:read_only)
    assert Permissions.mode("read") == :allow
    assert Permissions.mode("grep") == :allow
    assert Permissions.mode("write") == :ask
    assert Permissions.mode("bash") == :ask
  end

  test "full: everything runs" do
    Permissions.put_level(:full)
    assert Permissions.mode("bash") == :allow
    assert Permissions.mode("write") == :allow
    assert Permissions.mode("read") == :allow
  end

  test "auto: extension tools ask (they can fetch/write/run programs)" do
    Permissions.put_level(:auto)
    # Same gate as bash — an extension tool is arbitrary code, not a plain read.
    assert Permissions.mode("web_search", :extension) == :ask
    assert Permissions.mode("read", :builtin) == :allow
    # Defaulting source to :builtin keeps the existing name-only behavior.
    assert Permissions.mode("read") == :allow
  end

  test "read_only: extension tools ask" do
    Permissions.put_level(:read_only)
    assert Permissions.mode("web_search", :extension) == :ask
  end

  test "full: extension tools still run without prompts" do
    Permissions.put_level(:full)
    assert Permissions.mode("web_search", :extension) == :allow
  end
end
