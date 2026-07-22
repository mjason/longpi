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

  test "image attachments get pi-style [Image #N] labels before each image part" do
    png = Base.encode64(<<137, 80, 78, 71>>)

    context =
      ReqLLMClient.build_context([
        %{
          role: :user,
          content: "对比 [Image #1] 和 [Image #2]",
          attachments: [
            %{"type" => "image", "data" => png, "media_type" => "image/png", "name" => "a.png"},
            %{"type" => "file", "text" => "notes"},
            %{"type" => "image", "data" => png, "media_type" => "image/png", "name" => "b.png"}
          ]
        }
      ])

    [message] = context.messages
    texts = for %{type: :text, text: t} <- message.content, do: t

    assert "[Image #1: a.png]" in texts
    assert "[Image #2: b.png]" in texts

    # Ordering: label #1 immediately precedes the first image part.
    idx =
      Enum.find_index(message.content, fn part ->
        part.type == :text and part.text == "[Image #1: a.png]"
      end)

    assert Enum.at(message.content, idx + 1).type == :image
  end

end
