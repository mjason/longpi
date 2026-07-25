defmodule LongpiWeb.SidebarChannel do
  @moduledoc """
  Live sidebar updates: one channel per client, relaying unseen-activity
  badge changes for ALL conversations.

  The badge exists precisely for the user who is NOT looking at the flagged
  conversation — often with the window focused on another one, where the
  focus/visibility refetch never fires. Sessions broadcast every badge write
  on the `"sidebar"` PubSub topic; this channel pushes them as
  `attention_changed` so the sidebar patches its list in place.
  """

  use LongpiWeb, :channel

  @impl true
  def join("sidebar:updates", _payload, socket) do
    Phoenix.PubSub.subscribe(Longpi.PubSub, "sidebar")
    {:ok, socket}
  end

  @impl true
  def handle_info({:conversation_attention, conversation_id, kind}, socket) do
    push(socket, "attention_changed", %{id: conversation_id, kind: kind})
    {:noreply, socket}
  end
end
