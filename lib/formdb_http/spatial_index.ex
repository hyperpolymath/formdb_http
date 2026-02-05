# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule FormdbHttp.SpatialIndex do
  @moduledoc """
  R-tree spatial index for efficient geospatial queries.

  Provides O(log n + k) query performance where k = number of results.
  Uses ETS for in-memory storage.

  Features:
  - Bounding box indexing
  - Fast intersection queries
  - Automatic index updates
  - Per-database indexes

  Based on R-tree algorithm (Guttman 1984).
  """

  use GenServer
  require Logger

  @table_name :spatial_indexes
  @max_entries_per_node 8
  # Note: min_entries_per_node would be used for node underflow handling in production

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Create a spatial index for a database.
  """
  def create_index(db_id) do
    GenServer.call(__MODULE__, {:create_index, db_id})
  end

  @doc """
  Insert a feature into the spatial index.
  """
  def insert(db_id, feature_id, bbox) do
    GenServer.call(__MODULE__, {:insert, db_id, feature_id, bbox})
  end

  @doc """
  Query features intersecting a bounding box.
  Returns list of feature IDs.
  """
  def query(db_id, bbox) do
    GenServer.call(__MODULE__, {:query, db_id, bbox})
  end

  @doc """
  Delete a feature from the spatial index.
  """
  def delete(db_id, feature_id) do
    GenServer.call(__MODULE__, {:delete, db_id, feature_id})
  end

  @doc """
  Drop the spatial index for a database.
  """
  def drop_index(db_id) do
    GenServer.call(__MODULE__, {:drop_index, db_id})
  end

  # Server callbacks

  @impl true
  def init(:ok) do
    :ets.new(@table_name, [:named_table, :public, :set, {:write_concurrency, true}])
    Logger.info("Spatial index manager started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create_index, db_id}, _from, state) do
    # Create root node for this database
    root = create_node(:leaf, [])
    :ets.insert(@table_name, {{db_id, :root}, root})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:insert, db_id, feature_id, {minx, miny, maxx, maxy}}, _from, state) do
    case :ets.lookup(@table_name, {db_id, :root}) do
      [{_, root}] ->
        # Insert into R-tree
        new_root = insert_entry(root, {feature_id, {minx, miny, maxx, maxy}})
        :ets.insert(@table_name, {{db_id, :root}, new_root})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :index_not_found}, state}
    end
  end

  @impl true
  def handle_call({:query, db_id, bbox}, _from, state) do
    case :ets.lookup(@table_name, {db_id, :root}) do
      [{_, root}] ->
        # Search R-tree
        results = search_node(root, bbox)
        {:reply, {:ok, results}, state}

      [] ->
        {:reply, {:error, :index_not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete, db_id, feature_id}, _from, state) do
    case :ets.lookup(@table_name, {db_id, :root}) do
      [{_, root}] ->
        # Delete from R-tree
        new_root = delete_entry(root, feature_id)
        :ets.insert(@table_name, {{db_id, :root}, new_root})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :index_not_found}, state}
    end
  end

  @impl true
  def handle_call({:drop_index, db_id}, _from, state) do
    :ets.delete(@table_name, {db_id, :root})
    {:reply, :ok, state}
  end

  # R-tree implementation (simplified)

  defp create_node(type, entries) do
    %{
      type: type,  # :leaf or :internal
      entries: entries,
      bbox: compute_node_bbox(entries)
    }
  end

  defp insert_entry(node, entry) do
    case node.type do
      :leaf ->
        insert_into_leaf(node, entry)

      :internal ->
        insert_into_internal(node, entry)
    end
  end

  defp insert_into_leaf(node, {feature_id, bbox}) do
    new_entries = node.entries ++ [{feature_id, bbox}]

    if length(new_entries) > @max_entries_per_node do
      # Split node
      split_node(node, new_entries)
    else
      # Update node
      %{node | entries: new_entries, bbox: compute_node_bbox(new_entries)}
    end
  end

  defp insert_into_internal(node, entry) do
    # Choose subtree with minimum bbox enlargement
    best_child_idx = choose_subtree(node.entries, elem(entry, 1))
    {child_ref, _child_bbox} = Enum.at(node.entries, best_child_idx)

    # For simplicity, store children inline (in production, use references)
    updated_child = insert_entry(child_ref, entry)

    new_entries = List.replace_at(node.entries, best_child_idx, {updated_child, updated_child.bbox})

    if length(new_entries) > @max_entries_per_node do
      split_node(node, new_entries)
    else
      %{node | entries: new_entries, bbox: compute_node_bbox(new_entries)}
    end
  end

  defp split_node(node, entries) do
    # Simple split: divide entries in half (linear split)
    mid = div(length(entries), 2)
    {left_entries, right_entries} = Enum.split(entries, mid)

    left_node = create_node(node.type, left_entries)
    right_node = create_node(node.type, right_entries)

    # Create new parent
    create_node(:internal, [
      {left_node, left_node.bbox},
      {right_node, right_node.bbox}
    ])
  end

  defp choose_subtree(entries, bbox) do
    entries
    |> Enum.with_index()
    |> Enum.min_by(fn {{_child, child_bbox}, _idx} ->
      enlargement_area(child_bbox, bbox)
    end)
    |> elem(1)
  end

  defp search_node(node, search_bbox) do
    case node.type do
      :leaf ->
        # Check each entry in leaf
        node.entries
        |> Enum.filter(fn {_feature_id, bbox} ->
          bbox_intersects?(bbox, search_bbox)
        end)
        |> Enum.map(&elem(&1, 0))

      :internal ->
        # Recursively search children whose bbox intersects
        node.entries
        |> Enum.filter(fn {_child, child_bbox} ->
          bbox_intersects?(child_bbox, search_bbox)
        end)
        |> Enum.flat_map(fn {child, _bbox} ->
          search_node(child, search_bbox)
        end)
    end
  end

  defp delete_entry(node, feature_id) do
    case node.type do
      :leaf ->
        new_entries = Enum.reject(node.entries, fn {fid, _bbox} -> fid == feature_id end)
        %{node | entries: new_entries, bbox: compute_node_bbox(new_entries)}

      :internal ->
        new_entries =
          Enum.map(node.entries, fn {child, _bbox} ->
            updated_child = delete_entry(child, feature_id)
            {updated_child, updated_child.bbox}
          end)

        %{node | entries: new_entries, bbox: compute_node_bbox(new_entries)}
    end
  end

  # Geometry helpers

  defp compute_node_bbox([]), do: {0, 0, 0, 0}

  defp compute_node_bbox(entries) do
    entries
    |> Enum.map(fn {_ref, bbox} -> bbox end)
    |> Enum.reduce(fn {minx1, miny1, maxx1, maxy1}, {minx2, miny2, maxx2, maxy2} ->
      {min(minx1, minx2), min(miny1, miny2), max(maxx1, maxx2), max(maxy1, maxy2)}
    end)
  end

  defp bbox_intersects?({minx1, miny1, maxx1, maxy1}, {minx2, miny2, maxx2, maxy2}) do
    not (maxx1 < minx2 or minx1 > maxx2 or maxy1 < miny2 or miny1 > maxy2)
  end

  defp enlargement_area({minx1, miny1, maxx1, maxy1}, {minx2, miny2, maxx2, maxy2}) do
    # Calculate area increase if bbox2 is added to bbox1
    new_minx = min(minx1, minx2)
    new_miny = min(miny1, miny2)
    new_maxx = max(maxx1, maxx2)
    new_maxy = max(maxy1, maxy2)

    original_area = (maxx1 - minx1) * (maxy1 - miny1)
    new_area = (new_maxx - new_minx) * (new_maxy - new_miny)

    new_area - original_area
  end
end
