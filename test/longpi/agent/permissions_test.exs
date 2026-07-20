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
end
