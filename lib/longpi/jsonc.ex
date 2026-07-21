defmodule Longpi.Jsonc do
  @moduledoc """
  Strips `//` line and `/* */` block comments from JSONC so the config file can
  be commented. String contents (including escaped quotes) are preserved.
  """

  @doc "Removes JSONC comments, returning plain JSON text."
  @spec strip(binary()) :: binary()
  def strip(input) when is_binary(input) do
    input |> strip(:normal, []) |> Enum.reverse() |> IO.iodata_to_binary()
  end

  # Inside a string: copy everything through, honoring backslash escapes.
  defp strip(<<?\\, c, rest::binary>>, :string, acc), do: strip(rest, :string, [c, ?\\ | acc])
  defp strip(<<?", rest::binary>>, :string, acc), do: strip(rest, :normal, [?" | acc])
  defp strip(<<c, rest::binary>>, :string, acc), do: strip(rest, :string, [c | acc])

  # Normal text: watch for a string opening or a comment start.
  defp strip(<<?", rest::binary>>, :normal, acc), do: strip(rest, :string, [?" | acc])
  defp strip(<<?/, ?/, rest::binary>>, :normal, acc), do: strip(rest, :line, acc)
  defp strip(<<?/, ?*, rest::binary>>, :normal, acc), do: strip(rest, :block, acc)
  defp strip(<<c, rest::binary>>, :normal, acc), do: strip(rest, :normal, [c | acc])

  # Line comment runs to (and keeps) the newline.
  defp strip(<<?\n, rest::binary>>, :line, acc), do: strip(rest, :normal, [?\n | acc])
  defp strip(<<_c, rest::binary>>, :line, acc), do: strip(rest, :line, acc)

  # Block comment runs to the closing `*/`.
  defp strip(<<?*, ?/, rest::binary>>, :block, acc), do: strip(rest, :normal, acc)
  defp strip(<<_c, rest::binary>>, :block, acc), do: strip(rest, :block, acc)

  defp strip(<<>>, _state, acc), do: acc
end
