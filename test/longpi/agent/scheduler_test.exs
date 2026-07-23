defmodule Longpi.Agent.SchedulerTest do
  use Longpi.DataCase, async: false

  import Mox

  alias Longpi.Agent.Scheduler

  setup :set_mox_global

  setup do
    # The fired task starts a real turn; a quiet stub keeps the log clean.
    stub(Longpi.Agent.LLM.Mock, :stream, fn _, _, _, _, _sink ->
      {:ok, %{text: "done", tool_calls: []}}
    end)

    :ok
  end

  describe "cron matching" do
    test "validate accepts standard 5-field expressions and rejects junk" do
      assert {:ok, _} = Scheduler.validate("0 23 * * *")
      assert {:ok, _} = Scheduler.validate("*/15 * * * *")
      assert {:ok, _} = Scheduler.validate("30 9 * * 1-5")
      assert {:error, message} = Scheduler.validate("often")
      assert message =~ "invalid cron"
    end

    test "validate rejects 6-field (seconds-style) cron loudly" do
      # The parser would read the 6th field as a YEAR and silently misfire —
      # a common LLM output shape, so it must be an explicit error.
      assert {:error, message} = Scheduler.validate("0 0 23 * * *")
      assert message =~ "exactly 5 fields"
      assert {:error, _} = Scheduler.validate("0 23 * *")
    end

    test "due? matches the exact minute" do
      eleven_pm = ~N[2026-07-23 23:00:30]
      assert Scheduler.due?("0 23 * * *", eleven_pm)
      refute Scheduler.due?("0 23 * * *", ~N[2026-07-23 22:59:00])
      # Thursday 2026-07-23: weekday filters apply.
      assert Scheduler.due?("0 23 * * 4", eleven_pm)
      refute Scheduler.due?("0 23 * * 5", eleven_pm)
      assert Scheduler.due?("*/15 * * * *", ~N[2026-07-23 08:45:00])
    end

    test "next_run computes an upcoming time" do
      assert {:ok, %NaiveDateTime{}} = Scheduler.next_run("0 23 * * *")
      assert :error = Scheduler.next_run("garbage")
    end
  end

  describe "run_due_tasks/1" do
    test "fires a due task into its conversation and stamps last_run_at" do
      conversation = Longpi.Agent.create_conversation!(%{cwd: System.tmp_dir!(), model: "test:model"})

      task =
        Longpi.Agent.create_scheduled_task!(%{
          conversation_id: conversation.id,
          cron: "0 23 * * *",
          task: "nightly summary"
        })

      # Not due at 22:59 — nothing happens, no session started.
      Scheduler.run_due_tasks(~N[2026-07-23 22:59:00])
      assert Longpi.Agent.Sessions.whereis(conversation.id) == nil

      # Due at 23:00 — the session boots and receives the injected message.
      Scheduler.run_due_tasks(~N[2026-07-23 23:00:10])

      session = Longpi.Agent.Sessions.whereis(conversation.id)
      assert is_pid(session)

      # The injected user message reached the session (a turn starts; the mock
      # LLM isn't stubbed here, so just assert the message is in history).
      wait_until(fn ->
        Enum.any?(Longpi.Agent.Session.messages(session), fn
          %{role: :user, content: content} -> content =~ "[scheduled 0 23 * * *] nightly summary"
          _ -> false
        end)
      end)

      [reloaded] = Longpi.Agent.scheduled_tasks_for!(conversation.id)
      assert reloaded.id == task.id
      assert %DateTime{} = reloaded.last_run_at
    end
  end

  describe "cron semantics under real conditions" do
    test "a disabled task never fires" do
      conversation =
        Longpi.Agent.create_conversation!(%{cwd: System.tmp_dir!(), model: "test:model"})

      task =
        Longpi.Agent.create_scheduled_task!(%{
          conversation_id: conversation.id,
          cron: "* * * * *",
          task: "should not run",
          enabled: false
        })

      Scheduler.run_due_tasks(~N[2026-07-23 12:00:00])

      assert Longpi.Agent.Sessions.whereis(conversation.id) == nil
      [reloaded] = Longpi.Agent.scheduled_tasks_for!(conversation.id)
      assert reloaded.id == task.id
      assert reloaded.last_run_at == nil
    end

    test "a schedule whose conversation was deleted disables itself instead of warning forever" do
      conversation =
        Longpi.Agent.create_conversation!(%{cwd: System.tmp_dir!(), model: "test:model"})

      task =
        Longpi.Agent.create_scheduled_task!(%{
          conversation_id: conversation.id,
          cron: "* * * * *",
          task: "orphaned work"
        })

      Longpi.Agent.destroy_conversation!(conversation)

      Scheduler.run_due_tasks(~N[2026-07-23 12:00:00])

      [reloaded] = Longpi.Agent.scheduled_tasks_for!(task.conversation_id)
      assert reloaded.enabled == false
    end

    test "a busy session skips this occurrence (no queueing, no crash)" do
      conversation =
        Longpi.Agent.create_conversation!(%{cwd: System.tmp_dir!(), model: "test:model"})

      Longpi.Agent.create_scheduled_task!(%{
        conversation_id: conversation.id,
        cron: "* * * * *",
        task: "tick work"
      })

      # Occupy the session with a slow turn.
      stub(Longpi.Agent.LLM.Mock, :stream, fn _, _, _, _, _sink ->
        Process.sleep(400)
        {:ok, %{text: "slow", tool_calls: []}}
      end)

      {:ok, session} = Longpi.Agent.Sessions.ensure_started(conversation.id, [])
      :ok = Longpi.Agent.Session.send_message(session, "occupy")

      Scheduler.run_due_tasks(~N[2026-07-23 12:00:00])

      # Skipped: no scheduled message got queued behind the busy turn.
      [reloaded] = Longpi.Agent.scheduled_tasks_for!(conversation.id)
      assert reloaded.last_run_at == nil

      wait_until(fn -> Longpi.Agent.Session.status(session) == :idle end)

      refute Enum.any?(Longpi.Agent.Session.messages(session), fn
               %{role: :user, content: content} -> is_binary(content) and content =~ "[scheduled"
               _ -> false
             end)
    end
  end

  defp wait_until(fun, tries \\ 40) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(50)
        wait_until(fun, tries - 1)
    end
  end
end
