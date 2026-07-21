defmodule Longpi.Agent.LLM.ReqLLMClientTest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.LLM.ReqLLMClient
  alias Longpi.Agent.Message
  alias ReqLLM.Message.ContentPart

  # A real 1x1 PNG, base64-encoded — matches the wire shape (string keys).
  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

  defp image_attachment(data \\ @png_base64) do
    %{"type" => "image", "media_type" => "image/png", "data" => data, "name" => "pixel.png"}
  end

  test "a plain user message translates to a string-content user message" do
    context = ReqLLMClient.build_context([Message.user("hello")])
    assert [%ReqLLM.Message{role: :user} = message] = context.messages
    assert [%ContentPart{type: :text, text: "hello"}] = message.content
  end

  test "an image attachment becomes a decoded image ContentPart with its media_type" do
    message = Message.user("look at this", [image_attachment()])
    context = ReqLLMClient.build_context([message])

    assert [%ReqLLM.Message{role: :user, content: parts}] = context.messages

    assert Enum.any?(parts, fn
             %ContentPart{type: :text, text: "look at this"} -> true
             _ -> false
           end)

    assert [%ContentPart{type: :image, data: bytes, media_type: "image/png"}] =
             Enum.filter(parts, &(&1.type == :image))

    # data is the decoded binary, not the base64 string
    assert bytes == Base.decode64!(@png_base64)
  end

  test "a file attachment becomes a text ContentPart" do
    file = %{"type" => "file", "text" => "file contents here", "name" => "notes.txt"}
    context = ReqLLMClient.build_context([Message.user("read this", [file])])

    assert [%ReqLLM.Message{content: parts}] = context.messages
    texts = for %ContentPart{type: :text, text: t} <- parts, do: t
    assert "file contents here" in texts
    assert "read this" in texts
  end

  test "attachments with malformed base64 are skipped, keeping the valid ones" do
    bad = image_attachment("not-valid-base64!!!")
    good = image_attachment()

    context = ReqLLMClient.build_context([Message.user("mixed", [bad, good])])

    assert [%ReqLLM.Message{content: parts}] = context.messages
    images = Enum.filter(parts, &(&1.type == :image))
    assert length(images) == 1
    assert hd(images).data == Base.decode64!(@png_base64)
  end

  test "an image-only message (no text) yields just the image part" do
    context = ReqLLMClient.build_context([Message.user("", [image_attachment()])])

    assert [%ReqLLM.Message{content: parts}] = context.messages
    assert [%ContentPart{type: :image}] = parts
  end
end
