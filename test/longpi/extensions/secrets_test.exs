defmodule Longpi.Extensions.SecretsTest do
  use Longpi.DataCase, async: false

  alias Longpi.Extensions

  test "put/secret_env/list/delete roundtrip" do
    assert :ok = Extensions.put_secret("TAVILY_API_KEY", "tvly-123")
    assert :ok = Extensions.put_secret("OPENAI_API_KEY", "sk-xyz")

    assert Extensions.secret_env() == %{
             "TAVILY_API_KEY" => "tvly-123",
             "OPENAI_API_KEY" => "sk-xyz"
           }

    # Names surface sorted; values do not.
    assert Extensions.list_secret_names() == ["OPENAI_API_KEY", "TAVILY_API_KEY"]

    assert :ok = Extensions.delete_secret("OPENAI_API_KEY")
    assert Extensions.list_secret_names() == ["TAVILY_API_KEY"]
  end

  test "put upserts by name (re-saving replaces the value)" do
    assert :ok = Extensions.put_secret("KEY", "old")
    assert :ok = Extensions.put_secret("KEY", "new")
    assert Extensions.secret_env() == %{"KEY" => "new"}
  end

  test "deleting a missing secret is a no-op" do
    assert :ok = Extensions.delete_secret("NOPE")
  end

  test "the value attribute is sensitive and hidden from inspect" do
    assert :ok = Extensions.put_secret("SECRET_KEY", "super-secret-value")
    {:ok, [record]} = Longpi.Agent.list_extension_secrets()
    refute inspect(record) =~ "super-secret-value"
  end
end
