# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule FormdbHttpWeb.MetricsController do
  @moduledoc """
  Prometheus metrics endpoint.

  Exposes application metrics in Prometheus text format at /metrics.
  """

  use FormdbHttpWeb, :controller

  alias FormdbHttpWeb.Metrics.Collector

  @doc """
  Export metrics in Prometheus text format.
  """
  def index(conn, _params) do
    metrics_text = Collector.export_prometheus()

    # Add system metrics
    system_metrics = collect_system_metrics()
    all_metrics = metrics_text <> "\n" <> system_metrics

    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, all_metrics)
  end

  defp collect_system_metrics do
    memory = :erlang.memory()
    process_count = :erlang.system_info(:process_count)
    run_queue = :erlang.statistics(:run_queue)

    """
    # HELP erlang_vm_memory_total Total memory used by the Erlang VM
    # TYPE erlang_vm_memory_total gauge
    erlang_vm_memory_total #{memory[:total]}

    # HELP erlang_vm_memory_processes Memory used by Erlang processes
    # TYPE erlang_vm_memory_processes gauge
    erlang_vm_memory_processes #{memory[:processes]}

    # HELP erlang_vm_process_count Number of Erlang processes
    # TYPE erlang_vm_process_count gauge
    erlang_vm_process_count #{process_count}

    # HELP erlang_vm_run_queue_length Run queue length
    # TYPE erlang_vm_run_queue_length gauge
    erlang_vm_run_queue_length #{run_queue}
    """
  end
end
