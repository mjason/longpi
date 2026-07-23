defmodule Longpi.Agent.SchedulesTest do
  # Behavior specs for cron schedules — both front doors (the model-facing
  # `schedule` tool and the /schedule command helpers) share Schedules.
  use Longpi.DataCase, async: false

  alias Longpi.Agent.Schedules
  alias Longpi.Agent.Tools.Schedule, as: Tool

  setup do
    conversation =
      Longpi.Agent.create_conversation!(%{cwd: System.tmp_dir!(), model: "test:model"})

    %{ctx: %{conversation_id: conversation.id}, conversation_id: conversation.id}
  end

  describe "the user asks for a nightly summary in natural language" do
    test "the model translates it to cron and adds it via the tool", %{ctx: ctx} do
      assert {:ok, message} =
               Tool.run(%{action: "add", cron: "0 23 * * *", task: "总结今天的对话和完成的工作"}, ctx)

      assert message =~ "Scheduled [0 23 * * *]"
      assert message =~ "First run:"

      assert {:ok, listing} = Tool.run(%{action: "list"}, ctx)
      assert listing =~ "1. [0 23 * * *] 总结今天的对话和完成的工作"
      assert listing =~ "next "
    end

    test "an invalid cron comes back as a correctable error, nothing is stored", %{ctx: ctx} do
      assert {:error, message} = Tool.run(%{action: "add", cron: "every day", task: "x"}, ctx)
      assert message =~ "invalid cron"
      assert {:ok, "No schedules" <> _} = Tool.run(%{action: "list"}, ctx)
    end

    test "a blank task is rejected", %{conversation_id: id} do
      assert {:error, message} = Schedules.add(id, "0 23 * * *", "   ")
      assert message =~ "must not be empty"
    end
  end

  describe "the user cancels a schedule" do
    test "remove by the number shown in list", %{ctx: ctx, conversation_id: id} do
      {:ok, _} = Schedules.add(id, "0 23 * * *", "nightly")
      {:ok, _} = Schedules.add(id, "*/15 * * * *", "poll queue")

      assert {:ok, message} = Tool.run(%{action: "remove", index: 1}, ctx)
      assert message =~ "nightly"

      assert {:ok, listing} = Tool.run(%{action: "list"}, ctx)
      assert listing =~ "poll queue"
      refute listing =~ "nightly"
    end

    test "an out-of-range number errors with guidance", %{ctx: ctx} do
      assert {:error, message} = Tool.run(%{action: "remove", index: 7}, ctx)
      assert message =~ "no schedule #7"
    end
  end

  describe "tool robustness" do
    test "unknown action, missing params, and unpersisted conversations all error clearly", %{
      ctx: ctx
    } do
      assert {:error, m1} = Tool.run(%{action: "someday"}, ctx)
      assert m1 =~ "unknown action"

      assert {:error, m2} = Tool.run(%{action: "add", cron: "0 23 * * *"}, ctx)
      assert m2 =~ "needs both cron and task"

      assert {:error, m3} = Tool.run(%{action: "remove"}, ctx)
      assert m3 =~ "needs index"

      assert {:error, m4} = Tool.run(%{action: "list"}, %{conversation_id: nil})
      assert m4 =~ "persisted conversation"
    end

    test "schedules are scoped to their conversation", %{conversation_id: id} do
      other = Longpi.Agent.create_conversation!(%{cwd: System.tmp_dir!(), model: "test:model"})
      {:ok, _} = Schedules.add(id, "0 23 * * *", "mine")

      assert Schedules.list_text(other.id) =~ "No schedules"
      # Removing from the other conversation cannot touch this one's rows.
      assert {:error, _} = Schedules.remove(other.id, 1)
      assert Schedules.list_text(id) =~ "mine"
    end
  end
end
