defmodule Longpi.Agent.Tools.ContinueLater do
  @moduledoc """
  Lets the model schedule its own next turn: when a task is too large to finish
  in one turn, it calls this with a note, finishes the turn normally, and the
  session immediately wakes it with that note as the next user message.

  This is the implicit counterpart of the explicit `/loop` command — same
  continuation engine in `Longpi.Agent.Session`, same runaway protection (a
  consecutive-auto-turn cap that only a real user message resets).
  """

  @behaviour Longpi.Agent.Tool

  @impl true
  def name, do: "continue_later"

  @impl true
  def description do
    "Schedule your own next turn for work that doesn't fit in this one: pass a " <>
      "note describing exactly where to pick up, finish this turn with a short " <>
      "status, and you will be woken with the note. Set delay (e.g. \"10m\") to " <>
      "wake later instead of immediately — for waiting on deploys, CI, or " <>
      "anything external. Consecutive auto-turns are capped, so keep each " <>
      "turn's progress concrete."
  end

  @impl true
  def parameter_schema do
    [
      note: [
        type: :string,
        required: true,
        doc:
          "Self-reminder for the next turn: what is done, what to do next, and " <>
            "any state worth carrying over (paths, decisions, remaining items)."
      ],
      delay: [
        type: :string,
        doc:
          "How long to wait before waking: \"30s\", \"10m\", \"2h\", or plain " <>
            "seconds. Omit to continue immediately after this turn."
      ]
    ]
  end

  @impl true
  def run(args, ctx) do
    with {:ok, delay_ms} <- parse_delay(args[:delay]) do
      case GenServer.call(ctx.session, {:schedule_continuation, args.note, delay_ms}) do
        :ok when delay_ms > 0 ->
          {:ok,
           "Continuation scheduled in #{args[:delay]}. Finish this turn; " <>
             "you'll be woken with your note."}

        :ok ->
          {:ok, "Continuation scheduled. Finish this turn; you'll be woken with your note."}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # "30s" / "10m" / "2h" / "90" (seconds) → milliseconds. Capped at 24h.
  @doc false
  def parse_delay(nil), do: {:ok, 0}
  def parse_delay(""), do: {:ok, 0}

  def parse_delay(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, unit} when n > 0 ->
        ms =
          case String.trim(unit) do
            "" -> n * 1_000
            "s" -> n * 1_000
            "m" -> n * 60_000
            "h" -> n * 3_600_000
            _ -> nil
          end

        if ms, do: {:ok, min(ms, 24 * 3_600_000)}, else: delay_error(text)

      _ ->
        delay_error(text)
    end
  end

  def parse_delay(_), do: {:ok, 0}

  defp delay_error(text) do
    {:error, "invalid delay #{inspect(text)} — use \"30s\", \"10m\", \"2h\", or plain seconds"}
  end
end
