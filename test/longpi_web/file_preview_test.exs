defmodule LongpiWeb.FilePreviewTest do
  use LongpiWeb.ConnCase, async: false

  @moduletag :tmp_dir

  describe "GET /rpc/file (preview)" do
    test "text file returns content", %{conn: conn, tmp_dir: dir} do
      path = Path.join(dir, "notes.md")
      File.write!(path, "# 标题\nhello world\n")

      body =
        conn
        |> get("/rpc/file", %{"path" => path})
        |> json_response(200)

      assert body["kind"] == "text"
      assert body["name"] == "notes.md"
      assert body["content"] =~ "hello world"
      assert body["truncated"] == false
    end

    test "relative path resolves against cwd", %{conn: conn, tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/app.ex"), "defmodule App do\nend\n")

      body =
        conn
        |> get("/rpc/file", %{"path" => "lib/app.ex", "cwd" => dir})
        |> json_response(200)

      assert body["kind"] == "text"
      assert body["path"] == Path.join(dir, "lib/app.ex")
    end

    test "absolute-looking path falls back to cwd-relative (origin-resolved hrefs)", %{
      conn: conn,
      tmp_dir: dir
    } do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/app.ex"), "defmodule App do\nend\n")

      body =
        conn
        |> get("/rpc/file", %{"path" => "/lib/app.ex", "cwd" => dir})
        |> json_response(200)

      assert body["kind"] == "text"
      assert body["path"] == Path.join(dir, "lib/app.ex")
    end

    test "binary file is flagged, no content leaked", %{conn: conn, tmp_dir: dir} do
      path = Path.join(dir, "blob.bin")
      File.write!(path, <<0, 1, 2, 255, 254, 0, 0>>)

      body =
        conn
        |> get("/rpc/file", %{"path" => path})
        |> json_response(200)

      assert body["kind"] == "binary"
      refute Map.has_key?(body, "content")
    end

    test "image file reports kind image", %{conn: conn, tmp_dir: dir} do
      path = Path.join(dir, "pic.png")
      File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0>>)

      body =
        conn
        |> get("/rpc/file", %{"path" => path})
        |> json_response(200)

      assert body["kind"] == "image"
      assert body["mime"] == "image/png"
    end

    test "large text file is truncated at the cap", %{conn: conn, tmp_dir: dir} do
      path = Path.join(dir, "big.log")
      File.write!(path, String.duplicate("x", 300_000))

      body =
        conn
        |> get("/rpc/file", %{"path" => path})
        |> json_response(200)

      assert body["kind"] == "text"
      assert body["truncated"] == true
      assert byte_size(body["content"]) <= 256_000
    end

    test "missing file 404s", %{conn: conn, tmp_dir: dir} do
      conn = get(conn, "/rpc/file", %{"path" => Path.join(dir, "nope.txt")})
      assert json_response(conn, 404)["error"] == "not_found"
    end

    test "directory 404s", %{conn: conn, tmp_dir: dir} do
      conn = get(conn, "/rpc/file", %{"path" => dir})
      assert json_response(conn, 404)["error"] == "not_found"
    end
  end

  describe "GET /rpc/file/raw" do
    test "serves bytes inline with the file's MIME type", %{conn: conn, tmp_dir: dir} do
      path = Path.join(dir, "pic.png")
      File.write!(path, <<137, 80, 78, 71>>)

      conn = get(conn, "/rpc/file/raw", %{"path" => path})

      assert response(conn, 200) == <<137, 80, 78, 71>>
      assert response_content_type(conn, :png)
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "inline"
    end

    test "download=1 sets attachment disposition with utf-8 filename", %{
      conn: conn,
      tmp_dir: dir
    } do
      path = Path.join(dir, "策略.py")
      File.write!(path, "print('hi')\n")

      conn = get(conn, "/rpc/file/raw", %{"path" => path, "download" => "1"})

      assert response(conn, 200) =~ "print"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "filename*=UTF-8''"
    end

    test "missing file 404s", %{conn: conn, tmp_dir: dir} do
      conn = get(conn, "/rpc/file/raw", %{"path" => Path.join(dir, "nope.bin")})
      assert conn.status == 404
    end
  end
end
