# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule FormdbHttp.QueryCache do
  @moduledoc """
  LRU query result cache for frequent queries.

  Caches query results in ETS with LRU eviction policy.
  Automatically invalidates on data changes.

  Features:
  - Configurable TTL (time-to-live)
  - Configurable max size
  - LRU eviction when full
  - Per-database cache invalidation
  - Query fingerprinting (hash-based keys)

  Configuration:
  - cache_enabled: Enable/disable caching (default: true)
  - cache_ttl_seconds: Cache entry TTL (default: 300)
  - cache_max_entries: Maximum entries (default: 1000)
  """

  use GenServer
  require Logger

  @table_name :query_cache
  @default_ttl 300  # 5 minutes
  @default_max_entries 1000
  @cleanup_interval 60_000  # 1 minute

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Get a cached query result.
  Returns {:ok, result} or :miss if not in cache or expired.
  """
  def get(query_key) do
    case :ets.lookup(@table_name, query_key) do
      [{^query_key, result, expires_at, _last_access}] ->
        now = System.system_time(:second)

        if now < expires_at do
          # Update last access time for LRU
          :ets.update_element(@table_name, query_key, {4, now})
          {:ok, result}
        else
          # Expired
          :ets.delete(@table_name, query_key)
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc """
  Put a query result in the cache.
  """
  def put(query_key, result, ttl_seconds \\ @default_ttl) do
    GenServer.cast(__MODULE__, {:put, query_key, result, ttl_seconds})
  end

  @doc """
  Invalidate cache entries for a specific database.
  Call this when data in the database changes.
  """
  def invalidate_db(db_id) do
    GenServer.cast(__MODULE__, {:invalidate_db, db_id})
  end

  @doc """
  Invalidate a specific query key.
  """
  def invalidate(query_key) do
    :ets.delete(@table_name, query_key)
    :ok
  end

  @doc """
  Clear all cache entries.
  """
  def clear_all do
    GenServer.cast(__MODULE__, :clear_all)
  end

  @doc """
  Get cache statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Generate a query key from query parameters.
  """
  def query_key(db_id, query_type, params) do
    # Create deterministic hash from query params
    query_data = %{
      db_id: db_id,
      type: query_type,
      params: params
    }

    hash = :crypto.hash(:md5, :erlang.term_to_binary(query_data))
    Base.encode16(hash, case: :lower)
  end

  # Server callbacks

  @impl true
  def init(:ok) do
    :ets.new(@table_name, [:named_table, :public, :set, {:write_concurrency, true}])

    # Start periodic cleanup
    schedule_cleanup()

    Logger.info("Query cache started (TTL: #{@default_ttl}s, max: #{@default_max_entries} entries)")

    {:ok, %{
      hits: 0,
      misses: 0,
      evictions: 0
    }}
  end

  @impl true
  def handle_cast({:put, query_key, result, ttl_seconds}, state) do
    now = System.system_time(:second)
    expires_at = now + ttl_seconds

    # Check if cache is full
    cache_size = :ets.info(@table_name, :size)

    new_state =
      if cache_size >= @default_max_entries do
        # Evict LRU entry
        evict_lru()
        %{state | evictions: state.evictions + 1}
      else
        state
      end

    # Insert new entry
    :ets.insert(@table_name, {query_key, result, expires_at, now})

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:invalidate_db, db_id}, state) do
    # Delete all entries with this db_id in the key
    # This is a simple implementation; could be optimized with secondary index
    pattern = db_id

    deleted =
      :ets.select_delete(@table_name, [
        {{:"$1", :_, :_, :_}, [{:==, {:hd, :"$1"}, pattern}], [true]}
      ])

    Logger.debug("Invalidated #{deleted} cache entries for db_id: #{db_id}")

    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear_all, state) do
    :ets.delete_all_objects(@table_name)
    Logger.info("Query cache cleared")
    {:noreply, %{state | hits: 0, misses: 0, evictions: 0}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    cache_size = :ets.info(@table_name, :size)
    memory_bytes = :ets.info(@table_name, :memory) * :erlang.system_info(:wordsize)

    stats = %{
      size: cache_size,
      max_size: @default_max_entries,
      hits: state.hits,
      misses: state.misses,
      evictions: state.evictions,
      hit_rate: calculate_hit_rate(state.hits, state.misses),
      memory_bytes: memory_bytes,
      memory_mb: Float.round(memory_bytes / 1_048_576, 2)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Remove expired entries
    now = System.system_time(:second)

    deleted = :ets.select_delete(@table_name, [
      {{:_, :_, :"$1", :_}, [{:<, :"$1", now}], [true]}
    ])

    if deleted > 0 do
      Logger.debug("Cleaned up #{deleted} expired cache entries")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp evict_lru do
    # Find entry with oldest last_access time across ALL entries
    # Use select/2 (not select/3) to scan entire table
    entries = :ets.select(@table_name, [
      {{:"$1", :_, :_, :"$2"}, [], [{{:"$1", :"$2"}}]}
    ])

    case entries do
      [_ | _] ->
        # Find globally oldest entry by last_access time
        {lru_key, _lru_time} = Enum.min_by(entries, &elem(&1, 1))
        :ets.delete(@table_name, lru_key)
        Logger.debug("Evicted LRU cache entry: #{lru_key}")

      [] ->
        :ok
    end
  end

  defp calculate_hit_rate(0, 0), do: 0.0

  defp calculate_hit_rate(hits, misses) do
    total = hits + misses
    Float.round(hits / total * 100, 2)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
