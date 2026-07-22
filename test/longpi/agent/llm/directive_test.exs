defmodule Longpi.Agent.LLM.DirectiveTest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.LLM.ReqLLMClient

  test "file directives become pi-style @path for the model" do
    assert ReqLLMClient.normalize_directives(
             "看看 :file[foo.ts]{name=src/foo.ts} 和 :file[b c.md]{name=docs/b c.md}"
           ) == "看看 @src/foo.ts 和 @docs/b c.md"
  end

  test "plain text and non-file directives pass through" do
    assert ReqLLMClient.normalize_directives("hello @already/plain.txt") ==
             "hello @already/plain.txt"

    assert ReqLLMClient.normalize_directives(":tool[Calc]{name=calc}") ==
             ":tool[Calc]{name=calc}"
  end
end
