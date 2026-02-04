# SPDX-License-Identifier: PMPL-1.0-or-later
# FormBD-Analytics HTTP Controller

defmodule FormdbHttpWeb.AnalyticsController do
  use FormdbHttpWeb, :controller

  alias FormdbHttp.{Analytics, DatabaseRegistry}

  @doc "POST /api/v1/databases/:db_id/timeseries - Insert time-series data"
  def insert(conn, %{"db_id" => db_id} = params) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        with {:ok, series_id} <- get_param(params, "series_id"),
             {:ok, timestamp_str} <- get_param(params, "timestamp"),
             {:ok, value} <- get_param(params, "value"),
             {:ok, timestamp} <- parse_timestamp(timestamp_str),
             :ok <- Analytics.validate_value(value) do
          metadata = Map.get(params, "metadata", %{})
          provenance = Map.get(params, "provenance", %{})

          case Analytics.insert_timeseries(db_handle, series_id, timestamp, value, metadata, provenance) do
            {:ok, %{point_id: point_id, block_id: block_id}} ->
              # Convert block_id to binary if it's a list
              block_id_binary = if is_list(block_id), do: :binary.list_to_bin(block_id), else: block_id

              json(conn, %{
                point_id: point_id,
                block_id: Base.encode64(block_id_binary),
                stored_at: DateTime.utc_now() |> DateTime.to_iso8601()
              })

            {:error, reason} ->
              conn
              |> put_status(:internal_server_error)
              |> json(%{error: %{code: "INSERT_FAILED", message: to_string(reason)}})
          end
        else
          {:error, field} when is_binary(field) ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: %{code: "INVALID_REQUEST", message: "Missing or invalid field: #{field}"}})

          {:error, reason} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: %{code: "INVALID_REQUEST", message: to_string(reason)}})
        end
    end
  end

  @doc "GET /api/v1/databases/:db_id/timeseries/:series_id - Query time-series data"
  def query(conn, %{"db_id" => db_id, "series_id" => series_id} = params) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        # Parse query parameters
        start_time = parse_timestamp_param(params, "start", DateTime.utc_now() |> DateTime.add(-3600, :second))
        end_time = parse_timestamp_param(params, "end", DateTime.utc_now())
        aggregation = parse_aggregation(Map.get(params, "aggregation", "none"))
        interval = Map.get(params, "interval")
        limit = Map.get(params, "limit", "1000") |> parse_int(1000)

        case Analytics.query_timeseries(db_handle, series_id, start_time, end_time, aggregation, interval, limit) do
          {:ok, result} ->
            json(conn, result)

          {:error, reason} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: %{code: "QUERY_FAILED", message: to_string(reason)}})
        end
    end
  end

  @doc "GET /api/v1/databases/:db_id/timeseries/:series_id/aggregate - Aggregate time-series data"
  def aggregate(conn, %{"db_id" => db_id, "series_id" => series_id} = params) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        # Parse query parameters
        start_time = parse_timestamp_param(params, "start", DateTime.utc_now() |> DateTime.add(-3600, :second))
        end_time = parse_timestamp_param(params, "end", DateTime.utc_now())
        aggregation = parse_aggregation(Map.get(params, "aggregation", "avg"))
        interval = Map.get(params, "interval")
        limit = Map.get(params, "limit", "1000") |> parse_int(1000)

        case Analytics.query_timeseries(db_handle, series_id, start_time, end_time, aggregation, interval, limit) do
          {:ok, result} ->
            json(conn, result)

          {:error, reason} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: %{code: "QUERY_FAILED", message: to_string(reason)}})
        end
    end
  end

  @doc "GET /api/v1/databases/:db_id/timeseries/:series_id/provenance - Get time-series provenance"
  def provenance(conn, %{"db_id" => db_id, "series_id" => series_id}) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        case Analytics.get_timeseries_provenance(db_handle, series_id) do
          {:ok, provenance_data} ->
            json(conn, provenance_data)

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: %{code: "PROVENANCE_FAILED", message: to_string(reason)}})
        end
    end
  end

  @doc "GET /api/v1/databases/:db_id/timeseries/:series_id/latest - Get latest time-series point"
  def latest(conn, %{"db_id" => db_id, "series_id" => series_id}) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        # Query last hour, limit 1, no aggregation
        end_time = DateTime.utc_now()
        start_time = DateTime.add(end_time, -3600, :second)

        case Analytics.query_timeseries(db_handle, series_id, start_time, end_time, :none, nil, 1) do
          {:ok, %{data: [latest_point | _]}} ->
            json(conn, latest_point)

          {:ok, %{data: []}} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "NOT_FOUND", message: "No data points found"}})

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: %{code: "QUERY_FAILED", message: to_string(reason)}})
        end
    end
  end

  # ============================================================
  # Helper Functions
  # ============================================================

  defp get_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, key}
      value -> {:ok, value}
    end
  end

  defp parse_timestamp(timestamp_str) when is_binary(timestamp_str) do
    case DateTime.from_iso8601(timestamp_str) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _} -> {:error, "Invalid timestamp format. Use ISO 8601."}
    end
  end

  defp parse_timestamp(%DateTime{} = dt), do: {:ok, dt}
  defp parse_timestamp(_), do: {:error, "Invalid timestamp"}

  defp parse_timestamp_param(params, key, default) do
    case Map.get(params, key) do
      nil ->
        default

      timestamp_str ->
        case parse_timestamp(timestamp_str) do
          {:ok, dt} -> dt
          {:error, _} -> default
        end
    end
  end

  defp parse_aggregation(agg_str) when is_binary(agg_str) do
    case agg_str do
      "avg" -> :avg
      "min" -> :min
      "max" -> :max
      "sum" -> :sum
      "count" -> :count
      _ -> :none
    end
  end

  defp parse_aggregation(_), do: :none

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(n, _default) when is_integer(n), do: n
  defp parse_int(_, default), do: default
end
