defmodule Longpi.Shell.Result do
  @moduledoc """
  Outcome of a shell command run through the shim.

  `output` is the merged PTY stream (stdout and stderr interleaved, as a
  terminal would show them). When the command produced more than the head
  limit, the middle is dropped: `output` holds the head, `tail` the final
  bytes, and `dropped_bytes` how much was discarded in between.
  """

  defstruct output: "",
            tail: nil,
            exit_code: nil,
            dropped_bytes: 0,
            timed_out?: false,
            duration_ms: nil

  @type t :: %__MODULE__{
          output: binary(),
          tail: binary() | nil,
          exit_code: non_neg_integer() | nil,
          dropped_bytes: non_neg_integer(),
          timed_out?: boolean(),
          duration_ms: non_neg_integer() | nil
        }
end
