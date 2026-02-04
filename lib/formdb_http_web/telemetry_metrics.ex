# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule FormdbHttpWeb.TelemetryMetrics do
  @moduledoc """
  Prometheus metrics definitions for FormDB HTTP API.

  Exposes metrics at /metrics endpoint in Prometheus format.

  Metrics include:
  - HTTP request counts by method, path, and status
  - HTTP request duration histograms
  - FormDB operation counts
  - System resource usage
  """

  use Supervisor
  require Logger

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Prometheus metrics exporter (if library available)
      # For now, we'll track metrics internally
      {FormdbHttpWeb.Metrics.Collector, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Define Telemetry metrics to track.
  """
  def metrics do
    [
      # Phoenix HTTP metrics
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        tags: [:method, :path, :status],
        tag_values: &get_and_put_http_tags/1
      ),

      counter("phoenix.endpoint.stop.count",
        tags: [:method, :path, :status],
        tag_values: &get_and_put_http_tags/1
      ),

      # FormDB operation metrics
      counter("formdb.operation.count",
        tags: [:operation, :status]
      ),

      summary("formdb.operation.duration",
        unit: {:native, :millisecond},
        tags: [:operation]
      ),

      # VM metrics
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io")
    ]
  end

  defp get_and_put_http_tags(%{conn: conn} = metadata) do
    Map.merge(metadata, %{
      method: conn.method,
      path: conn.request_path,
      status: conn.status
    })
  end

  defp get_and_put_http_tags(metadata), do: metadata

  # Metric definition helpers
  defp summary(event_name, opts), do: {:summary, event_name, opts}
  defp counter(event_name, opts), do: {:counter, event_name, opts}
  defp last_value(event_name, opts \\ []), do: {:last_value, event_name, opts}
end
