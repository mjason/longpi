defmodule Longpi.Agent.CompactorTest do
  use ExUnit.Case, async: true

  import Mox

  alias Longpi.Agent.{Compactor, Message}
  alias Longpi.Agent.LLM.Mock, as: LLMMock

  setup :verify_on_exit!

  test "estimate_tokens is roughly chars/4" do
    assert Compactor.estimate_tokens(Message.user(String.duplicate("a", 40))) == 10
  end

  test "plan keeps the recent tail within keep_tokens and summarizes the rest" do
    # 8 messages of ~10 tokens each (40 chars); keep_tokens 25 -> keep last 2.
    messages = for i <- 1..8, do: Message.user("#{i}-" <> String.duplicate("x", 38))
    {to_summarize, to_keep} = Compactor.plan(messages, 25)

    assert length(to_keep) == 2
    assert length(to_summarize) == 6
    assert to_summarize ++ to_keep == messages
  end

  test "plan keeps a single message (nothing older to summarize)" do
    messages = [Message.user("only one")]
    assert Compactor.plan(messages, 5) == {[], messages}
  end

  test "plan always keeps at least the most recent message" do
    big = String.duplicate("x", 400)
    messages = [Message.user("first " <> big), Message.user("second " <> big)]
    {to_summarize, to_keep} = Compactor.plan(messages, 10)
    assert length(to_keep) == 1
    assert length(to_summarize) == 1
  end

  test "summarize calls the LLM with the messages plus an instruction" do
    to_summarize = [Message.user("did a thing"), Message.assistant("done")]

    expect(LLMMock, :stream, fn "test:model", messages, [], [], _sink ->
      assert %{role: :system} = hd(messages)
      assert Enum.any?(messages, &(&1[:content] == "did a thing"))
      assert List.last(messages).content =~ "context checkpoint"
      {:ok, %{text: "## Goal\nstuff", tool_calls: []}}
    end)

    assert {:ok, summary} = Compactor.summarize(LLMMock, "test:model", to_summarize)
    assert summary =~ "Goal"
  end

  test "summarize threads a previous summary for incremental updates" do
    expect(LLMMock, :stream, fn _, messages, _, _, _ ->
      assert List.last(messages).content =~ "previous-summary"
      {:ok, %{text: "updated", tool_calls: []}}
    end)

    assert {:ok, "updated"} =
             Compactor.summarize(LLMMock, "test:model", [Message.user("new")], "OLD SUMMARY")
  end

  test "summarize surfaces LLM errors (so the Session can fall back)" do
    expect(LLMMock, :stream, fn _, _, _, _, _ -> {:error, :boom} end)
    assert {:error, :boom} = Compactor.summarize(LLMMock, "test:model", [Message.user("x")])
  end
end
