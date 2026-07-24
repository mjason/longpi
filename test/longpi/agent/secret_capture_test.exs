defmodule Longpi.Agent.SecretCaptureTest do
  # Behavior: a user pastes a token as @@NAME=value@@; the value lands in the
  # secrets store and the text the model/history sees carries only the name.
  use Longpi.DataCase, async: false

  alias Longpi.Agent.SecretCapture

  defp stored, do: Longpi.Extensions.secret_env()

  test "captures a marked token: stores the value, text keeps only a placeholder" do
    {clean, names} =
      SecretCapture.capture("帮我配置 HA,token 是 @@HOME_ASSISTANT_TOKEN=eyJhbGciOi.secret@@ 谢谢")

    assert names == ["HOME_ASSISTANT_TOKEN"]
    assert clean == "帮我配置 HA,token 是 [secret HOME_ASSISTANT_TOKEN saved] 谢谢"
    refute clean =~ "eyJhbGciOi"
    assert stored()["HOME_ASSISTANT_TOKEN"] == "eyJhbGciOi.secret"
  end

  test "multiple markers in one message all capture" do
    {clean, names} = SecretCapture.capture("@@API_KEY=k1@@ and @@API_SECRET=k2@@")

    assert names == ["API_KEY", "API_SECRET"]
    assert clean == "[secret API_KEY saved] and [secret API_SECRET saved]"
    assert stored()["API_KEY"] == "k1"
    assert stored()["API_SECRET"] == "k2"
  end

  test "values may contain =, spaces, and newlines" do
    {_clean, ["PEM_KEY"]} =
      SecretCapture.capture("@@PEM_KEY=-----BEGIN KEY-----\nab=c/d+e\n-----END-----@@")

    assert stored()["PEM_KEY"] =~ "BEGIN KEY"
    assert stored()["PEM_KEY"] =~ "ab=c/d+e"
  end

  test "re-sending the same name overwrites (rotate a token by just sending it again)" do
    SecretCapture.capture("@@TOKEN=old@@")
    SecretCapture.capture("@@TOKEN=new@@")
    assert stored()["TOKEN"] == "new"
  end

  test "plain text, lowercase names, and lone @@ pass through untouched" do
    assert {"no secrets here", []} = SecretCapture.capture("no secrets here")
    assert {"email me @@ home", []} = SecretCapture.capture("email me @@ home")
    # lowercase names don't look like env vars — left as-is, nothing stored
    {clean, []} = SecretCapture.capture("@@lower=value@@")
    assert clean == "@@lower=value@@"
    assert stored() == %{}
  end

  describe "anonymous value → AI names it (the user only supplies the value)" do
    alias Longpi.Agent.Tools.NameSecret

    test "an unnamed marker stores under a PENDING handle and tells the model to name it" do
      {clean, [pending]} = SecretCapture.capture("这是 HA 的 token @@=eyJxyz.anon@@")

      assert pending =~ ~r/^PENDING_[0-9A-F]{6}$/
      assert clean =~ "[unnamed secret stored as #{pending} — name it with the name_secret tool]"
      refute clean =~ "eyJxyz"
      # Pending values are held back from extensions until named.
      refute Map.has_key?(Longpi.Extensions.secret_env(), pending)
    end

    test "name_secret moves the value to the real name, without exposing it" do
      {_clean, [pending]} = SecretCapture.capture("@@=the-real-token@@")

      assert {:ok, message} =
               NameSecret.run(%{pending: pending, name: "HOME_ASSISTANT_TOKEN"}, %{})

      assert message =~ "process.env.HOME_ASSISTANT_TOKEN"
      refute message =~ "the-real-token"
      assert stored()["HOME_ASSISTANT_TOKEN"] == "the-real-token"
      refute Map.has_key?(stored(), pending)
    end

    test "name_secret refuses bad handles, bad names, and renaming real secrets" do
      SecretCapture.capture("@@REAL_KEY=v@@")

      assert {:error, m1} = NameSecret.run(%{pending: "REAL_KEY", name: "OTHER"}, %{})
      assert m1 =~ "not a pending handle"

      {_c, [pending]} = SecretCapture.capture("@@=v2@@")
      assert {:error, m2} = NameSecret.run(%{pending: pending, name: "bad name"}, %{})
      assert m2 =~ "invalid name"

      assert {:error, m3} = NameSecret.run(%{pending: pending, name: "PENDING_NEW"}, %{})
      assert m3 =~ "must not start with PENDING_"

      assert {:error, m4} = NameSecret.run(%{pending: "PENDING_GONE99", name: "X"}, %{})
      assert m4 =~ "no pending secret"
      # The real pending handle is listed as a hint.
      assert m4 =~ pending
    end
  end

  test "an oversized value is refused loudly, not silently truncated" do
    big = String.duplicate("x", 5000)
    {clean, names} = SecretCapture.capture("@@BIG=#{big}@@")

    assert names == []
    assert clean =~ "[secret BIG NOT saved — value exceeds"
    refute clean =~ "xxxxx"
    assert stored() == %{}
  end

  test "per-message cap: only the first 5 are stored, the rest say so" do
    markers = Enum.map_join(1..7, " ", fn i -> "@@KEY_#{i}=v#{i}@@" end)
    {clean, names} = SecretCapture.capture(markers)

    assert length(names) == 5
    assert clean =~ "[secret KEY_6 NOT saved"
    assert stored()["KEY_5"] == "v5"
    refute Map.has_key?(stored(), "KEY_6")
  end
end
