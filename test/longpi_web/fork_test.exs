defmodule LongpiWeb.ForkTest do
  use LongpiWeb.ConnCase, async: false

  test "fork copies history up to the position into a fresh conversation", %{conn: conn} do
    source =
      Longpi.Agent.create_conversation!(%{cwd: "/tmp/fork-src", model: "test:model", title: "研究"})

    for {role, content, position} <- [
          {:user, "q1", 0},
          {:assistant, "a1", 1},
          {:user, "q2", 2},
          {:assistant, "a2", 3}
        ] do
      Longpi.Agent.append_message!(%{
        role: role,
        content: content,
        position: position,
        conversation_id: source.id
      })
    end

    # Fork at position 1: keep q1 + a1, drop the second turn.
    body =
      conn
      |> post(~p"/rpc/conversations/fork", %{"conversation_id" => source.id, "position" => 1})
      |> json_response(200)

    assert body["cwd"] == "/tmp/fork-src"
    assert body["title"] == "研究 ⑂"

    copied = Longpi.Agent.list_messages!(body["id"])
    assert Enum.map(copied, &{&1.role, &1.content}) == [{:user, "q1"}, {:assistant, "a1"}]

    # The source is untouched.
    assert length(Longpi.Agent.list_messages!(source.id)) == 4
  end

  test "fork of an unknown conversation 404s", %{conn: conn} do
    conn =
      post(conn, ~p"/rpc/conversations/fork", %{
        "conversation_id" => Ash.UUID.generate(),
        "position" => 0
      })

    assert json_response(conn, 404)
  end

  test "/rpc/files lists workspace files for @ mentions", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "files-ep-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "src/foo.ts"), "x")
    File.write!(Path.join(dir, "README.md"), "x")

    %{"files" => files} =
      conn |> get(~p"/rpc/files", %{"cwd" => dir}) |> json_response(200)

    assert "src/foo.ts" in files
    assert "README.md" in files

    %{"files" => filtered} =
      conn |> get(~p"/rpc/files", %{"cwd" => dir, "q" => "foo"}) |> json_response(200)

    assert filtered == ["src/foo.ts"]
  end

end
