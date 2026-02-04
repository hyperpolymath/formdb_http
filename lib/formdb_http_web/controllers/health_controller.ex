# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule FormdbHttpWeb.HealthController do
  @moduledoc """
  Health check endpoints for monitoring and orchestration.

  Provides multiple health check endpoints:
  - GET /health - Basic health check
  - GET /health/live - Kubernetes liveness probe
  - GET /health/ready - Kubernetes readiness probe
  - GET /health/detailed - Detailed system health metrics
  """

  use FormdbHttpWeb, :controller

  alias FormdbHttp.FormDB

  @doc """
  Basic health check - returns 200 OK if service is running.
  """
  def index(conn, _params) do
    json(conn, %{
      status: "healthy",
      service: "formdb-http",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  @doc """
  Liveness probe for Kubernetes.
  Returns 200 if the application process is alive.
  """
  def live(conn, _params) do
    json(conn, %{
      status: "alive",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  @doc """
  Readiness probe for Kubernetes.
  Returns 200 if the application is ready to serve traffic.
  Checks:
  - FormDB NIF is loaded
  - Required dependencies available
  """
  def ready(conn, _params) do
    checks = %{
      formdb_nif: check_formdb_nif(),
      erlang_vm: check_erlang_vm()
    }

    all_ready = Enum.all?(checks, fn {_key, val} -> val == :ok end)

    status_code = if all_ready, do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(%{
      status: if(all_ready, do: "ready", else: "not_ready"),
      checks: checks,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  @doc """
  Detailed health check with system metrics.
  Includes:
  - Memory usage
  - Process count
  - Uptime
  - FormDB version
  - Active connections
  """
  def detailed(conn, _params) do
    {:ok, version} = FormDB.version()

    memory = :erlang.memory()
    system_info = %{
      total_memory: memory[:total],
      process_memory: memory[:processes],
      atom_memory: memory[:atom],
      binary_memory: memory[:binary],
      ets_memory: memory[:ets]
    }

    process_info = %{
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      run_queue: :erlang.statistics(:run_queue)
    }

    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    uptime_seconds = div(uptime_ms, 1000)

    formdb_info = %{
      version: version,
      nif_loaded: check_formdb_nif() == :ok
    }

    json(conn, %{
      status: "healthy",
      service: "formdb-http",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      uptime_seconds: uptime_seconds,
      system: system_info,
      processes: process_info,
      formdb: formdb_info
    })
  end

  # Private helper functions

  defp check_formdb_nif do
    try do
      case FormDB.version() do
        {:ok, _version} -> :ok
        {:error, _} -> :error
      end
    rescue
      _ -> :error
    end
  end

  defp check_erlang_vm do
    # Basic check that Erlang VM is functioning
    try do
      :erlang.system_info(:process_count)
      :ok
    rescue
      _ -> :error
    end
  end
end
