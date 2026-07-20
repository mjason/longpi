defmodule Longpi.Agent.LLM.ReqLLMClientLiveTest do
  @moduledoc """
  Smoke tests against a real provider API. Excluded by default; run with:

      ANTHROPIC_API_KEY=... mix test --include live_llm

  Override the model with LONGPI_LIVE_MODEL (default: a cheap Anthropic one).
  """

  use ExUnit.Case, async: false

  alias Longpi.Agent.{Message, Toolbox, Turn}
  alias Longpi.Agent.LLM.ReqLLMClient

  @moduletag :live_llm
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  defp model, do: System.get_env("LONGPI_LIVE_MODEL", "anthropic:claude-haiku-4-5")

  test "streams text and reports deltas" do
    test_pid = self()
    sink = fn event -> send(test_pid, {:ev, event}) end

    assert {:ok, completion} =
             ReqLLMClient.stream(
               model(),
               [Message.user("Reply with exactly the word: pineapple")],
               [],
               [],
               sink
             )

    assert completion.text =~ ~r/pineapple/i
    assert completion.tool_calls == []
    assert_received {:ev, {:text_delta, _}}
  end

  test "drives a real tool round trip through Turn", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "secret.txt"), "the magic word is XYZZY-42")
    test_pid = self()

    config = %{
      llm: ReqLLMClient,
      model: model(),
      toolbox: Toolbox.new(),
      ctx: %{cwd: dir},
      sink: fn event -> send(test_pid, {:ev, event}) end
    }

    prompt = "Read the file secret.txt with the read tool and repeat the magic word it contains."
    assert {:ok, new_messages} = Turn.run(config, [Message.user(prompt)])

    final = List.last(new_messages)
    assert final.role == :assistant
    assert final.content =~ "XYZZY-42"

    assert_received {:ev, {:tool_call, %{name: "read"}}}
  end
end
