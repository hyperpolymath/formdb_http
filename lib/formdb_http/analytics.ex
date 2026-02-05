# SPDX-License-Identifier: PMPL-1.0-or-later
# FormBD-Analytics - Time-series analytics with provenance

defmodule FormdbHttp.Analytics do
  @moduledoc """
  Time-series analytics operations with provenance tracking.
  Handles time-series data storage, querying, and aggregation.
  """

  @type timeseries_point :: %{
          timestamp: DateTime.t(),
          value: float(),
          metadata: map(),
          provenance: map()
        }

  @type aggregation :: :none | :avg | :min | :max | :sum | :count
  @type interval :: String.t()

  @doc """
  Insert a time-series data point with provenance.
  Returns point ID and block ID.
  """
  @spec insert_timeseries(reference(), String.t(), DateTime.t(), float(), map(), map()) ::
          {:ok, %{point_id: String.t(), block_id: binary()}} | {:error, term()}
  def insert_timeseries(db_handle, series_id, timestamp, value, metadata, provenance) do
    alias FormdbHttp.{FormDB, CBOR, TemporalIndex, QueryCache}

    # Generate unique point ID
    point_id = generate_point_id()
    timestamp_unix = DateTime.to_unix(timestamp, :second)

    # Create time-series point
    point = %{
      type: "TimeSeries",
      id: point_id,
      series_id: series_id,
      timestamp: DateTime.to_iso8601(timestamp),
      timestamp_unix: timestamp_unix,
      value: value,
      metadata: metadata,
      provenance: provenance,
      stored_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Encode as CBOR
    case CBOR.encode(point) do
      {:ok, cbor_data} ->
        # Store in database via transaction
        case FormDB.with_transaction(db_handle, :read_write, fn txn ->
               FormDB.apply_operation(txn, cbor_data)
             end) do
          {:ok, {:ok, block_id}} ->
            # Update temporal index
            db_id = extract_db_id(db_handle)
            TemporalIndex.insert(db_id, series_id, point_id, timestamp_unix)

            # Invalidate query cache
            QueryCache.invalidate_db(db_id)

            # Publish to PubSub for real-time subscribers
            Phoenix.PubSub.broadcast(
              FormdbHttp.PubSub,
              "journal:#{db_id}",
              {:journal_event, point}
            )

            {:ok, %{point_id: point_id, block_id: block_id}}

          {:ok, block_id} when is_binary(block_id) ->
            # Update temporal index
            db_id = extract_db_id(db_handle)
            TemporalIndex.insert(db_id, series_id, point_id, timestamp_unix)

            # Invalidate cache and publish event
            QueryCache.invalidate_db(db_id)

            Phoenix.PubSub.broadcast(
              FormdbHttp.PubSub,
              "journal:#{db_id}",
              {:journal_event, point}
            )

            {:ok, %{point_id: point_id, block_id: block_id}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:cbor_encode_failed, reason}}
    end
  end

  defp extract_db_id(db_handle) when is_reference(db_handle) do
    # Extract database ID from handle reference
    inspect(db_handle)
  end

  defp extract_db_id(_), do: "unknown"

  @doc """
  Query time-series data with optional aggregation.
  """
  @spec query_timeseries(reference(), String.t(), DateTime.t(), DateTime.t(), aggregation(), interval() | nil, integer()) ::
          {:ok, map()} | {:error, term()}
  def query_timeseries(db_handle, series_id, start_time, end_time, aggregation, interval, limit) do
    alias FormdbHttp.{FormDB, CBOR, TemporalIndex, QueryCache}

    db_id = extract_db_id(db_handle)
    start_unix = DateTime.to_unix(start_time, :second)
    end_unix = DateTime.to_unix(end_time, :second)

    # Generate cache key
    cache_key = QueryCache.query_key(db_id, :timeseries, %{
      series_id: series_id,
      start: start_unix,
      end: end_unix,
      aggregation: aggregation,
      interval: interval,
      limit: limit
    })

    # Check cache first
    case QueryCache.get(cache_key) do
      {:ok, cached_result} ->
        {:ok, cached_result}

      :miss ->
        # Use temporal index if available
        points =
          case TemporalIndex.range_query(db_id, series_id, start_unix, end_unix, limit) do
            {:ok, [_ | _] = point_ids} ->
              # M13: Use temporal index to get point IDs, then fetch points
              fetch_points_by_ids(db_handle, series_id, point_ids)

            {:ok, []} ->
              # Index returned no results
              []

            {:error, :index_not_found} ->
              # Fall back to linear scan (M12 behavior)
              linear_scan_timeseries(db_handle, series_id, start_unix, end_unix, limit)
          end

        # Apply aggregation if requested
        data =
          case aggregation do
            :none ->
              points

            agg when agg in [:avg, :min, :max, :sum, :count] ->
              if interval do
                aggregate_by_interval(points, agg, interval, start_time, end_time)
              else
                # Aggregate all points into one value
                [%{value: aggregate(points, agg)}]
              end
          end

        result = %{
          series_id: series_id,
          start: DateTime.to_iso8601(start_time),
          end: DateTime.to_iso8601(end_time),
          aggregation: aggregation,
          interval: interval,
          data: data
        }

        # Cache the result
        QueryCache.put(cache_key, result)

        {:ok, result}
    end
  end

  @doc """
  Get provenance summary for a time-series.
  """
  @spec get_timeseries_provenance(reference(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_timeseries_provenance(_db_handle, series_id) do
    # M10 PoC: Return dummy provenance summary
    {:ok,
     %{
       series_id: series_id,
       provenance_summary: %{
         sources: ["sensor", "manual_entry"],
         quality_distribution: %{
           calibrated: 0.95,
           uncalibrated: 0.05
         },
         total_points: 0
       }
     }}
  end

  @doc """
  Aggregate time-series data over an interval.
  """
  @spec aggregate(list(timeseries_point()), aggregation()) :: float() | nil
  def aggregate([], _), do: nil

  def aggregate(points, :avg) do
    values = Enum.map(points, & &1.value)
    Enum.sum(values) / length(values)
  end

  def aggregate(points, :min) do
    points
    |> Enum.map(& &1.value)
    |> Enum.min()
  end

  def aggregate(points, :max) do
    points
    |> Enum.map(& &1.value)
    |> Enum.max()
  end

  def aggregate(points, :sum) do
    points
    |> Enum.map(& &1.value)
    |> Enum.sum()
  end

  def aggregate(points, :count), do: length(points)

  def aggregate(points, :none), do: points

  @doc """
  Parse interval string (e.g., "1m", "5m", "1h", "1d").
  Returns interval in seconds.
  """
  @spec parse_interval(String.t()) :: {:ok, integer()} | {:error, String.t()}
  def parse_interval(interval_str) do
    case Regex.run(~r/^(\d+)([smhd])$/, interval_str) do
      [_, num, unit] ->
        n = String.to_integer(num)

        seconds =
          case unit do
            "s" -> n
            "m" -> n * 60
            "h" -> n * 3600
            "d" -> n * 86400
          end

        {:ok, seconds}

      _ ->
        {:error, "Invalid interval format. Use: 1s, 5m, 1h, 1d"}
    end
  end

  @doc """
  Validate time-series value.
  """
  @spec validate_value(any()) :: :ok | {:error, String.t()}
  def validate_value(value) when is_number(value), do: :ok
  def validate_value(_), do: {:error, "Value must be a number"}

  # ============================================================
  # Private Functions
  # ============================================================

  defp generate_point_id do
    "ts_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  # Helper functions for querying

  defp is_timeseries_point?(%{"type" => "TimeSeries"}), do: true
  defp is_timeseries_point?(_), do: false

  defp matches_series?(%{"series_id" => sid}, series_id), do: sid == series_id
  defp matches_series?(_, _), do: false

  defp in_time_range?(%{"timestamp_unix" => ts}, start_unix, end_unix) do
    ts >= start_unix and ts <= end_unix
  end

  defp in_time_range?(_, _, _), do: false

  defp aggregate_by_interval(points, aggregation, interval, start_time, end_time) do
    case parse_interval(interval) do
      {:ok, interval_seconds} ->
        # Group points into time buckets
        buckets = group_by_interval(points, interval_seconds, start_time, end_time)

        # Aggregate each bucket
        Enum.map(buckets, fn {bucket_start, bucket_points} ->
          %{
            timestamp: DateTime.to_iso8601(bucket_start),
            value: aggregate(bucket_points, aggregation)
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp group_by_interval(points, interval_seconds, start_time, _end_time) do
    start_unix = DateTime.to_unix(start_time, :second)

    points
    |> Enum.group_by(fn point ->
      ts = Map.get(point, "timestamp_unix", 0)
      bucket_index = div(ts - start_unix, interval_seconds)
      DateTime.add(start_time, bucket_index * interval_seconds, :second)
    end)
    |> Enum.sort_by(fn {bucket_start, _} -> DateTime.to_unix(bucket_start, :second) end)
  end

  defp linear_scan_timeseries(db_handle, series_id, start_unix, end_unix, limit) do
    alias FormdbHttp.{FormDB, CBOR}

    case FormDB.get_journal(db_handle, 0) do
      {:ok, journal_cbor} ->
        case CBOR.decode(journal_cbor) do
          {:ok, journal_entries} when is_list(journal_entries) ->
            journal_entries
            |> Enum.filter(&is_timeseries_point?/1)
            |> Enum.filter(&matches_series?(&1, series_id))
            |> Enum.filter(&in_time_range?(&1, start_unix, end_unix))
            |> Enum.take(limit)

          {:ok, _} ->
            []

          {:error, _} ->
            []
        end

      {:error, _} ->
        []
    end
  end

  defp fetch_points_by_ids(db_handle, series_id, point_ids) do
    alias FormdbHttp.{FormDB, CBOR}

    # Fetch journal and filter by IDs
    case FormDB.get_journal(db_handle, 0) do
      {:ok, journal_cbor} ->
        case CBOR.decode(journal_cbor) do
          {:ok, journal_entries} when is_list(journal_entries) ->
            id_set = MapSet.new(point_ids)

            journal_entries
            |> Enum.filter(fn entry ->
              is_timeseries_point?(entry) and
                matches_series?(entry, series_id) and
                MapSet.member?(id_set, Map.get(entry, "id"))
            end)

          _ ->
            []
        end

      _ ->
        []
    end
  end
end
