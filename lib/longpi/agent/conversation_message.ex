defmodule Longpi.Agent.ConversationMessage do
  @moduledoc """
  One persisted conversation message.

  System prompts are never stored - they are rebuilt from config at session
  start, so prompt changes apply to old conversations too. `from_message/3`
  and `to_message/1` convert between rows and the plain-map format used by
  the agent loop (`Longpi.Agent.Message`).
  """

  use Ash.Resource,
    otp_app: :longpi,
    domain: Longpi.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "conversation_messages"
    repo Longpi.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :role,
        :content,
        :attachments,
        :tool_calls,
        :tool_call_id,
        :tool_name,
        :error,
        :position,
        :conversation_id
      ]
    end

    read :for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id))
      prepare build(sort: [position: :asc])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:user, :assistant, :tool]
    end

    attribute :content, :string do
      allow_nil? false
      default ""
      public? true
      # Message content is data, not user input: keep "" and whitespace as-is.
      constraints allow_empty?: true, trim?: false
    end

    attribute :tool_calls, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    # User-message attachments: string-keyed maps (image = base64 + media_type,
    # file = inlined text). Stored as JSON, so keys stay strings on the way back.
    attribute :attachments, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    attribute :tool_call_id, :string do
      public? true
    end

    attribute :tool_name, :string do
      public? true
    end

    attribute :error, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :position, :integer do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :conversation, Longpi.Agent.Conversation do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  @doc "Converts an agent-loop message map to attrs for `:create`."
  def from_message(message, conversation_id, position) do
    %{
      conversation_id: conversation_id,
      position: position,
      role: message.role,
      content: message[:content] || "",
      attachments: message[:attachments] || [],
      tool_calls: Enum.map(message[:tool_calls] || [], &encode_call/1),
      tool_call_id: message[:tool_call_id],
      tool_name: message[:name],
      error: message[:error?] || false
    }
  end

  @doc "Converts a stored row back to the agent-loop message map."
  def to_message(%{role: :user} = record) do
    case record.attachments do
      [] -> %{role: :user, content: record.content}
      attachments -> %{role: :user, content: record.content, attachments: attachments}
    end
  end

  def to_message(%{role: :assistant} = record) do
    %{
      role: :assistant,
      content: record.content,
      tool_calls: Enum.map(record.tool_calls, &decode_call/1)
    }
  end

  def to_message(%{role: :tool} = record) do
    %{
      role: :tool,
      tool_call_id: record.tool_call_id,
      name: record.tool_name,
      content: record.content,
      error?: record.error
    }
  end

  defp encode_call(call), do: %{"id" => call.id, "name" => call.name, "args" => call.args}

  # JSON roundtrip through sqlite stringifies keys; args stay string-keyed
  # (Toolbox and the req_llm adapter both accept that).
  defp decode_call(%{"id" => id, "name" => name} = call) do
    %{id: id, name: name, args: call["args"] || %{}}
  end
end
