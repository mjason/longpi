defmodule Longpi.Workspace.GitTest do
  # Behavior: the git panel's whole lifecycle against a real throwaway repo —
  # status parsing (porcelain -z incl. renames/untracked), stage/unstage/
  # discard, commit, log, diff and file_at for the side-by-side viewer.
  use ExUnit.Case, async: true

  alias Longpi.Workspace.Git

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {_, 0} = System.cmd("git", ["-C", dir, "init", "-q", "-b", "main"])
    {_, 0} = System.cmd("git", ["-C", dir, "config", "user.email", "t@example.com"])
    {_, 0} = System.cmd("git", ["-C", dir, "config", "user.name", "Test"])
    %{repo: dir}
  end

  test "a plain directory reports repo: false", %{tmp_dir: dir} do
    outside = Path.join(System.tmp_dir!(), "not-a-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)

    # tmp_dir itself IS a repo (setup); use the sibling.
    assert {:ok, %{repo: false, root: nil, files: []}} = Git.status(outside)
    assert {:ok, %{repo: true}} = Git.status(dir)
  end

  test "status → stage → commit → log lifecycle", %{repo: repo} do
    File.write!(Path.join(repo, "a.txt"), "hello\n")

    {:ok, status} = Git.status(repo)
    assert status.branch == "main"
    assert [%{path: "a.txt", status: "??", staged: false, unstaged: true}] = status.files

    :ok = Git.stage(repo, "a.txt")
    {:ok, %{files: [%{path: "a.txt", status: "A", staged: true, unstaged: false}]}} =
      Git.status(repo)

    {:ok, hash} = Git.commit(repo, "add a", false)
    assert hash =~ ~r/^[0-9a-f]{4,}$/

    {:ok, [%{subject: "add a", author: "Test", hash: ^hash}]} = Git.log(repo, 50)
    {:ok, %{files: []}} = Git.status(repo)

    # show renders the commit patch.
    {:ok, %{text: text, truncated: false}} = Git.show(repo, hash)
    assert text =~ "add a" and text =~ "+hello"
  end

  test "modified file appears staged AND unstaged after a partial stage (MM)", %{repo: repo} do
    File.write!(Path.join(repo, "b.txt"), "one\n")
    :ok = Git.stage(repo, "b.txt")
    {:ok, _} = Git.commit(repo, "base", false)

    File.write!(Path.join(repo, "b.txt"), "one\ntwo\n")
    :ok = Git.stage(repo, "b.txt")
    File.write!(Path.join(repo, "b.txt"), "one\ntwo\nthree\n")

    {:ok, %{files: [entry]}} = Git.status(repo)
    assert entry.status == "MM"
    assert entry.staged and entry.unstaged
  end

  test "diff: staged vs unstaged sides, and untracked via no-index", %{repo: repo} do
    File.write!(Path.join(repo, "c.txt"), "base\n")
    :ok = Git.stage(repo, "c.txt")
    {:ok, _} = Git.commit(repo, "base", false)

    File.write!(Path.join(repo, "c.txt"), "base\nchanged\n")
    {:ok, %{diff: unstaged_diff, binary: false}} = Git.diff(repo, "c.txt", false)
    assert unstaged_diff =~ "+changed"

    :ok = Git.stage(repo, "c.txt")
    {:ok, %{diff: staged_diff}} = Git.diff(repo, "c.txt", true)
    assert staged_diff =~ "+changed"

    File.write!(Path.join(repo, "new.txt"), "fresh\n")
    {:ok, %{diff: untracked_diff}} = Git.diff(repo, "new.txt", false)
    assert untracked_diff =~ "+fresh"
  end

  test "file_at serves both diff sides; missing revisions are empty, not errors", %{repo: repo} do
    File.write!(Path.join(repo, "d.txt"), "v1\n")
    :ok = Git.stage(repo, "d.txt")
    {:ok, _} = Git.commit(repo, "v1", false)
    File.write!(Path.join(repo, "d.txt"), "v2\n")

    assert {:ok, %{content: "v1\n", missing: false}} = Git.file_at(repo, "HEAD", "d.txt")
    assert {:ok, %{content: "v2\n", missing: false}} = Git.file_at(repo, "WORKTREE", "d.txt")
    assert {:ok, %{missing: true}} = Git.file_at(repo, "HEAD", "never-existed.txt")
    assert {:ok, %{missing: true}} = Git.file_at(repo, "WORKTREE", "never-existed.txt")

    # Flag-smuggling revisions are refused outright.
    assert {:error, _} = Git.file_at(repo, "--output=/tmp/pwned", "d.txt")
  end

  test "unstage and discard, including the untracked-delete path", %{repo: repo} do
    File.write!(Path.join(repo, "e.txt"), "keep\n")
    :ok = Git.stage(repo, "e.txt")
    {:ok, _} = Git.commit(repo, "base", false)

    # Tracked discard restores the committed content.
    File.write!(Path.join(repo, "e.txt"), "dirty\n")
    :ok = Git.discard(repo, "e.txt")
    assert File.read!(Path.join(repo, "e.txt")) == "keep\n"

    # Unstage moves an added file back to untracked (unborn-safe path too).
    File.write!(Path.join(repo, "f.txt"), "x\n")
    :ok = Git.stage(repo, "f.txt")
    :ok = Git.unstage(repo, "f.txt")
    {:ok, %{files: files}} = Git.status(repo)
    assert %{status: "??"} = Enum.find(files, &(&1.path == "f.txt"))

    # Untracked discard deletes the file (dala semantics).
    :ok = Git.discard(repo, "f.txt")
    refute File.exists?(Path.join(repo, "f.txt"))
  end

  test "renames consume the extra porcelain token without corrupting the list", %{repo: repo} do
    File.write!(Path.join(repo, "old.txt"), "content\n")
    :ok = Git.stage(repo, "old.txt")
    {:ok, _} = Git.commit(repo, "base", false)

    {_, 0} = System.cmd("git", ["-C", repo, "mv", "old.txt", "renamed.txt"])
    File.write!(Path.join(repo, "other.txt"), "x\n")

    {:ok, %{files: files}} = Git.status(repo)
    assert %{status: "R", staged: true} = Enum.find(files, &(&1.path == "renamed.txt"))
    # The rename's ORIGINAL-path token didn't get misparsed as its own entry.
    refute Enum.any?(files, &(&1.path == "old.txt"))
    assert %{status: "??"} = Enum.find(files, &(&1.path == "other.txt"))
  end

  test "commit with amend rewrites the tip", %{repo: repo} do
    File.write!(Path.join(repo, "g.txt"), "x\n")
    :ok = Git.stage(repo, "g.txt")
    {:ok, _} = Git.commit(repo, "typo mesage", false)
    {:ok, _} = Git.commit(repo, "fixed message", true)

    {:ok, [%{subject: "fixed message"}]} = Git.log(repo, 50)
  end

  test "empty repo: log is empty, unstage falls back to rm --cached", %{repo: repo} do
    assert {:ok, []} = Git.log(repo, 10)

    File.write!(Path.join(repo, "h.txt"), "x\n")
    :ok = Git.stage(repo, "h.txt")
    :ok = Git.unstage(repo, "h.txt")
    {:ok, %{files: [%{path: "h.txt", status: "??"}]}} = Git.status(repo)
  end

  test "show refuses non-hash input", %{repo: repo} do
    assert {:error, _} = Git.show(repo, "HEAD; rm -rf /")
    assert {:error, _} = Git.show(repo, "--help")
  end
end
