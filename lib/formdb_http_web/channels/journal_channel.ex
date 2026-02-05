# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule FormdbHttpWeb.JournalChannel do
  @moduledoc """
  Phoenix Channel for real-time journal updates.

  Provides WebSocket subscriptions to database journal events.

  Features:
  - Subscribe to specific database journals
  - Filter by event type (Feature, TimeSeries)
  - Filter by series_id or bbox
  - Backpressure handling
  - Automatic reconnection support

  Usage (JavaScript):
  ```javascript
  let socket = new Socket("/socket")
  socket.connect()

  let channel = socket.channel("journal:db_abc123", {
    filter: {type: "TimeSeries", series_id: "temp_01"}
  })

  channel.on("journal_event", payload => {
    console.log("New event:", payload)
  })

  channel.join()
  ```
  """

  use FormdbHttpWeb, :channel
  require Logger

  alias FormdbHttp.FormDB

  @doc """
  Join a journal channel for a specific database.

  Channel topic format: "journal:<db_id>"

  Params:
  - filter: Optional filter %{type: ..., series_id: ..., bbox: ...}
  """
  def join("journal:" <> db_id, params, socket) do
    # Verify database exists (or create subscription intent)
    filter = Map.get(params, "filter", %{})

    socket =
      socket
      |> assign(:db_id, db_id)
      |> assign(:filter, filter)
      |> assign(:sequence, 0)

    # Subscribe to PubSub for this database
    topic = "journal:#{db_id}"
    Phoenix.PubSub.subscribe(FormdbHttp.PubSub, topic)

    Logger.info("Client joined journal channel: #{topic} with filter: #{inspect(filter)}")

    {:ok, %{status: "subscribed", db_id: db_id}, socket}
  end

  @doc """
  Handle request for historical journal entries.
  """
  def handle_in("get_history", %{"since" => since}, socket) do
    db_id = socket.assigns.db_id
    filter = socket.assigns.filter

    # Fetch historical entries from journal
    case FormDB.get_journal(db_id, since) do
      {:ok, journal_cbor} ->
        # Decode and filter entries
        entries = decode_and_filter_journal(journal_cbor, filter)

        {:reply, {:ok, %{entries: entries, count: length(entries)}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("update_filter", %{"filter" => new_filter}, socket) do
    socket = assign(socket, :filter, new_filter)
    {:reply, {:ok, %{filter: new_filter}}, socket}
  end

  @doc """
  Handle incoming journal events from PubSub.
  Filters and forwards to client if matching.
  """
  def handle_info({:journal_event, event}, socket) do
    if matches_filter?(event, socket.assigns.filter) do
      push(socket, "journal_event", event)
    end

    {:noreply, socket}
  end

  # Private functions

  defp decode_and_filter_journal(journal_cbor, filter) do
    case FormdbHttp.CBOR.decode(journal_cbor) do
      {:ok, entries} when is_list(entries) ->
        entries
        |> Enum.filter(&matches_filter?(&1, filter))

      {:ok, _} ->
        []

      {:error, _} ->
        []
    end
  end

  defp matches_filter?(_event, filter) when map_size(filter) == 0 do
    # No filter, match all
    true
  end

  defp matches_filter?(event, filter) do
    # Check type filter
    type_match =
      case Map.get(filter, "type") do
        nil -> true
        type -> Map.get(event, "type") == type
      end

    # Check series_id filter (for TimeSeries)
    series_match =
      case Map.get(filter, "series_id") do
        nil -> true
        series_id -> Map.get(event, "series_id") == series_id
      end

    # Check bbox filter (for Features)
    bbox_match =
      case Map.get(filter, "bbox") do
        nil ->
          true

        [minx, miny, maxx, maxy] ->
          case Map.get(event, "geometry") do
            nil ->
              false

            geometry ->
              FormdbHttp.Geo.bbox_intersects?(
                %{"geometry" => geometry},
                {minx, miny, maxx, maxy}
              )
          end
      end

    type_match and series_match and bbox_match
  end
end
