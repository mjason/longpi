defmodule Longpi.Agent.SecretCapture do
  @moduledoc """
  Out-of-band secret intake: a user message may carry `@@NAME=value@@`
  markers. Before the message reaches the session (and therefore the history,
  the DB, the broadcast, and the model), the marked values are stripped out
  and stored as extension secrets; the text keeps only a placeholder.

  The real value exists transiently here and then only in the secrets store —
  the model never sees it, yet can immediately use `process.env.NAME` in
  extensions. NAME must look like an environment variable (A-Z, 0-9, _,
  starting with a letter).
  """

  @marker ~r/@@([A-Z][A-Z0-9_]*)?=(.+?)@@/s
  @max_secrets_per_message 5
  @max_value_bytes 4096

  @doc """
  Extracts and stores every `@@NAME=value@@` in `text`; returns the text with
  each marker replaced by `[secret NAME saved]` plus the stored names.

  An anonymous marker — `@@=value@@`, no name — stores the value under a
  `PENDING_XXXX` handle; the model names it afterwards with the `name_secret`
  tool (the user supplies just the value, the AI decides the key, and the
  value still never reaches the model). Oversized values are refused loudly
  (better visible than silently half-saved).
  """
  @spec capture(String.t()) :: {String.t(), [String.t()]}
  def capture(text) when is_binary(text) do
    {clean, names} =
      Regex.split(@marker, text, include_captures: true)
      |> Enum.map_reduce([], fn part, names ->
        case Regex.run(@marker, part) do
          [^part, name, value] when byte_size(value) <= @max_value_bytes ->
            store(placeholder_name(name), value, names)

          [^part, name, _too_big] ->
            {"[secret #{display(name)} NOT saved — value exceeds #{@max_value_bytes} bytes]",
             names}

          _ ->
            {part, names}
        end
      end)

    {Enum.join(clean), Enum.reverse(names)}
  end

  def capture(other), do: {other, []}

  @doc "True when `name` is a pending (anonymous, not-yet-named) secret."
  @spec pending?(String.t()) :: boolean()
  def pending?(name), do: String.starts_with?(name, "PENDING_")

  defp store(name, value, names) do
    if length(names) < @max_secrets_per_message and
         Longpi.Extensions.put_secret(name, value) == :ok do
      note =
        if pending?(name),
          do: "[unnamed secret stored as #{name} — name it with the name_secret tool]",
          else: "[secret #{name} saved]"

      {note, [name | names]}
    else
      {"[secret #{name} NOT saved — limit reached or storage failed]", names}
    end
  end

  # Anonymous markers get a short random pending handle.
  defp placeholder_name(""), do: "PENDING_" <> (:crypto.strong_rand_bytes(3) |> Base.encode16())
  defp placeholder_name(name), do: name

  defp display(""), do: "(unnamed)"
  defp display(name), do: name
end
