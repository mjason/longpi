defmodule Longpi.Updater.GitHubTest do
  use ExUnit.Case, async: true

  alias Longpi.Updater.GitHub

  @release %{"tag_name" => "v9.9.9", "draft" => false, "prerelease" => false, "assets" => []}
  @now 1_000_000

  defp ok(status, opts \\ []) do
    {:ok,
     %{
       status: status,
       body: opts[:body] || "",
       headers: opts[:headers] || %{}
     }}
  end

  describe "interpret/3 — success" do
    test "200 returns the newest stable release and caches it with the ETag" do
      resp = ok(200, body: [@release], headers: %{"etag" => ["W/\"abc\""]})
      assert {{:ok, @release}, cache} = GitHub.interpret(resp, nil, @now)
      assert cache.release == @release
      assert cache.etag == "W/\"abc\""
      assert cache.fetched_at == @now
    end

    test "200 with no stable release errors and writes no cache" do
      draft = %{"tag_name" => "v9.9.9", "draft" => true}
      assert {{:error, msg}, nil} = GitHub.interpret(ok(200, body: [draft]), nil, @now)
      assert msg =~ "no releases"
    end
  end

  describe "interpret/3 — conditional revalidation" do
    test "304 keeps the cached release and refreshes its timestamp (no rate cost)" do
      cache = %{release: @release, etag: "W/\"abc\"", fetched_at: 1}
      assert {{:ok, @release}, new} = GitHub.interpret(ok(304), cache, @now)
      assert new.release == @release
      assert new.fetched_at == @now
      assert new.etag == "W/\"abc\""
    end
  end

  describe "interpret/3 — rate limit / failure fallback" do
    for status <- [403, 429] do
      test "#{status} serves the last known release instead of erroring" do
        cache = %{release: @release, etag: nil, fetched_at: 1}
        assert {{:ok, @release}, nil} = GitHub.interpret(ok(unquote(status)), cache, @now)
      end
    end

    test "403 with no cache surfaces a clear rate-limit error" do
      assert {{:error, msg}, nil} = GitHub.interpret(ok(403), nil, @now)
      assert msg =~ "rate limit"
    end

    test "a network error falls back to the cached release when present" do
      cache = %{release: @release, etag: nil, fetched_at: 1}
      err = {:error, %RuntimeError{message: "boom"}}
      assert {{:ok, @release}, nil} = GitHub.interpret(err, cache, @now)
    end

    test "a network error with no cache surfaces the reason" do
      err = {:error, %RuntimeError{message: "boom"}}
      assert {{:error, msg}, nil} = GitHub.interpret(err, nil, @now)
      assert msg =~ "boom"
    end

    test "404 means nothing published yet" do
      assert {{:error, msg}, nil} = GitHub.interpret(ok(404), nil, @now)
      assert msg =~ "no releases"
    end
  end
end
