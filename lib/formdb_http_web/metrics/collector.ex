# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule FormdbHttpWeb.Metrics.Collector do
  @moduledoc """
  Simple metrics collector using ETS.

  Stores metrics in memory and provides Prometheus-formatted export.
  """

  use GenServer
  require Logger

  @table_name :formdb_http_metrics

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Increment a counter metric.
  """
  def increment_counter(metric_name, labels \\ %{}, value \\ 1) do
    key = {metric_name, labels}
    :ets.update_counter(@table_name, key, {2, value}, {key, 0})
  end

  @doc """
  Record a histogram/summary value.
  """
  def record_value(metric_name, labels \\ %{}, value) do
    key = {metric_name, labels}
    GenServer.cast(__MODULE__, {:record_value, key, value})
  end

  @doc """
  Get all metrics in Prometheus text format.
  """
  def export_prometheus do
    GenServer.call(__MODULE__, :export_prometheus)
  end

  @doc """
  Get all metrics as a map.
  """
  def get_all_metrics do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {{metric, labels}, value} ->
      {metric, labels, value}
    end)
  end

  # Server callbacks

  @impl true
  def init(:ok) do
    :ets.new(@table_name, [:named_table, :public, :set, {:write_concurrency, true}])
    Logger.info("Metrics collector started")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record_value, key, value}, state) do
    # For simplicity, store as gauge (last value)
    # In production, would maintain histogram buckets
    :ets.insert(@table_name, {key, value})
    {:noreply, state}
  end

  @impl true
  def handle_call(:export_prometheus, _from, state) do
    metrics = get_all_metrics()
    prometheus_text = format_prometheus(metrics)
    {:reply, prometheus_text, state}
  end

  # Private helpers

  defp format_prometheus(metrics) do
    metrics
    |> Enum.group_by(fn {metric_name, _labels, _value} -> metric_name end)
    |> Enum.map(fn {metric_name, metric_values} ->
      format_metric_family(metric_name, metric_values)
    end)
    |> Enum.join("\n")
  end

  defp format_metric_family(metric_name, values) do
    metric_name_str = format_metric_name(metric_name)

    lines = [
      "# HELP #{metric_name_str} #{metric_name}",
      "# TYPE #{metric_name_str} gauge"
    ]

    value_lines =
      values
      |> Enum.map(fn {_name, labels, value} ->
        labels_str = format_labels(labels)
        "#{metric_name_str}#{labels_str} #{value}"
      end)

    (lines ++ value_lines) |> Enum.join("\n")
  end

  defp format_metric_name(name) when is_atom(name), do: Atom.to_string(name)
  defp format_metric_name(name) when is_binary(name), do: name

  defp format_labels(labels) when map_size(labels) == 0, do: ""

  defp format_labels(labels) do
    label_pairs =
      labels
      |> Enum.map(fn {k, v} ->
        ~s(#{k}="#{escape_label_value(v)}")
      end)
      |> Enum.join(",")

    "{#{label_pairs}}"
  end

  defp escape_label_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp escape_label_value(value), do: to_string(value)
end
