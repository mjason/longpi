defmodule LongpiWeb.ConfigControllerTest do
  use LongpiWeb.ConnCase

  test "GET /rpc/csrf returns a fresh CSRF token", %{conn: conn} do
    conn = get(conn, ~p"/rpc/csrf")
    assert %{"token" => token} = json_response(conn, 200)
    assert is_binary(token) and token != ""
  end

  describe "GET /rpc/dirs (directory completion for the new-conversation dialog)" do
    @describetag :tmp_dir

    test "a partial path lists matching subdirectories", %{conn: conn, tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "dev"))
      File.mkdir_p!(Path.join(dir, "documents"))
      File.mkdir_p!(Path.join(dir, "music"))
      File.write!(Path.join(dir, "devfile"), "not a dir")

      conn = get(conn, ~p"/rpc/dirs?prefix=#{dir <> "/d"}")
      assert %{"dirs" => dirs} = json_response(conn, 200)
      assert dirs == [Path.join(dir, "dev"), Path.join(dir, "documents")]
    end

    test "a trailing slash lists inside the directory; hidden dirs need an explicit dot",
         %{conn: conn, tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "visible"))
      File.mkdir_p!(Path.join(dir, ".hidden"))

      conn1 = get(conn, ~p"/rpc/dirs?prefix=#{dir <> "/"}")
      assert %{"dirs" => [only]} = json_response(conn1, 200)
      assert only == Path.join(dir, "visible")

      conn2 = get(conn, ~p"/rpc/dirs?prefix=#{dir <> "/."}")
      assert %{"dirs" => [hidden]} = json_response(conn2, 200)
      assert hidden == Path.join(dir, ".hidden")
    end

    test "a bogus path returns an empty list, not an error", %{conn: conn} do
      conn = get(conn, ~p"/rpc/dirs?prefix=/no/such/place/anywhere")
      assert %{"dirs" => []} = json_response(conn, 200)
    end
  end

  describe "POST /rpc/cron-next (the Schedules admin page's next-run column)" do
    test "returns a next run per valid cron and nil for junk", %{conn: conn} do
      conn = post(conn, ~p"/rpc/cron-next", %{"crons" => ["0 23 * * *", "not cron"]})

      assert %{"nexts" => nexts} = json_response(conn, 200)
      assert %{"0 23 * * *" => next, "not cron" => nil} = nexts
      # "YYYY-MM-DD HH:MM:SS" with the scheduled 23:00 minute.
      assert next =~ ~r/^\d{4}-\d{2}-\d{2} 23:00:00$/
    end

    test "an empty batch is fine", %{conn: conn} do
      conn = post(conn, ~p"/rpc/cron-next", %{"crons" => []})
      assert %{"nexts" => nexts} = json_response(conn, 200)
      assert nexts == %{}
    end

    test "non-string entries are dropped, not a 500", %{conn: conn} do
      conn = post(conn, ~p"/rpc/cron-next", %{"crons" => [123, nil, %{}, "0 9 * * *"]})
      assert %{"nexts" => nexts} = json_response(conn, 200)
      assert Map.keys(nexts) == ["0 9 * * *"]
    end

    test "the batch is capped (no CPU DoS via a huge hostile list)", %{conn: conn} do
      crons = Enum.map(1..500, fn i -> "#{rem(i, 60)} 9 * * *" end)
      conn = post(conn, ~p"/rpc/cron-next", %{"crons" => crons})
      assert %{"nexts" => nexts} = json_response(conn, 200)
      assert map_size(nexts) <= 100
    end
  end
end
