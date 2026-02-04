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
  def insert_timeseries(_db_handle, series_id, timestamp, value, metadata, provenance) do
    # Create time-series point
    point = %{
      series_id: series_id,
      timestamp: DateTime.to_iso8601(timestamp),
      value: value,
      metadata: metadata,
      provenance: provenance
    }

    # M10 PoC: Just validate and return dummy IDs
    point_id = generate_point_id()

    {:ok, %{point_id: point_id, block_id: <<0, 0, 0, 0, 0, 0, 0, 1>>}}
  end

  @doc """
  Query time-series data with optional aggregation.
  """
  @spec query_timeseries(reference(), String.t(), DateTime.t(), DateTime.t(), aggregation(), interval() | nil, integer()) ::
          {:ok, map()} | {:error, term()}
  def query_timeseries(_db_handle, series_id, start_time, end_time, aggregation, interval, limit) do
    # M10 PoC: Return empty data
    # M11+: Query time-series index with aggregation

    result = %{
      series_id: series_id,
      start: DateTime.to_iso8601(start_time),
      end: DateTime.to_iso8601(end_time),
      aggregation: aggregation,
      interval: interval,
      data: []
    }

    {:ok, result}
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
end
