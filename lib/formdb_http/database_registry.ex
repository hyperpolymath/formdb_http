# SPDX-License-Identifier: PMPL-1.0-or-later
# Database Handle Registry - Persistent storage for database handles across HTTP requests

defmodule FormdbHttp.DatabaseRegistry do
  @moduledoc """
  ETS-based registry for storing database handles and metadata.
  Allows handles to persist across HTTP requests.
  """

  use GenServer

  @table_name :formdb_database_registry

  # ============================================================
  # Client API
  # ============================================================

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Store a database handle with metadata"
  def put(db_id, db_handle, metadata \\ %{}) do
    :ets.insert(@table_name, {db_id, db_handle, metadata, DateTime.utc_now()})
    :ok
  end

  @doc "Get a database handle by ID (returns handle or nil, like Process.get)"
  def get(db_id) do
    case :ets.lookup(@table_name, db_id) do
      [{^db_id, db_handle, _metadata, _created_at}] -> db_handle
      [] -> nil
    end
  end

  @doc "Get database metadata (returns {:ok, metadata} or {:error, :not_found})"
  def get_metadata(db_id) do
    case :ets.lookup(@table_name, db_id) do
      [{^db_id, _db_handle, metadata, _created_at}] -> {:ok, metadata}
      [] -> {:error, :not_found}
    end
  end

  @doc "Delete a database handle"
  def delete(db_id) do
    :ets.delete(@table_name, db_id)
    :ok
  end

  @doc "List all database IDs"
  def list() do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {db_id, _handle, metadata, created_at} ->
      %{
        db_id: db_id,
        name: Map.get(metadata, :name),
        description: Map.get(metadata, :description),
        created_at: created_at
      }
    end)
  end

  # ============================================================
  # GenServer Callbacks
  # ============================================================

  @impl true
  def init(:ok) do
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
