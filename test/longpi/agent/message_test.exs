defmodule Longpi.Agent.MessageTest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.Message

  test "user/1 is text only, no :attachments key" do
    assert Message.user("hello") == %{role: :user, content: "hello"}
    refute Map.has_key?(Message.user("hello"), :attachments)
  end

  test "user/2 with an empty attachment list is identical to user/1" do
    assert Message.user("hi", []) == Message.user("hi")
    refute Map.has_key?(Message.user("hi", []), :attachments)
  end

  test "user/2 with attachments carries them under :attachments" do
    attachments = [
      %{"type" => "image", "media_type" => "image/png", "data" => "AAAA", "name" => "shot.png"}
    ]

    assert Message.user("look", attachments) ==
             %{role: :user, content: "look", attachments: attachments}
  end
end
