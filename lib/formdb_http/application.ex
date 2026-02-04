defmodule FormdbHttp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FormdbHttpWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:formdb_http, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: FormdbHttp.PubSub},
      # Metrics collector for Prometheus
      FormdbHttpWeb.Metrics.Collector,
      # Graceful shutdown handler
      FormdbHttp.GracefulShutdown,
      # Database handle registry (persists across HTTP requests)
      FormdbHttp.DatabaseRegistry,
      # M13: Spatial index for geospatial queries
      FormdbHttp.SpatialIndex,
      # M13: Temporal index for time-series queries
      FormdbHttp.TemporalIndex,
      # M13: Query result cache
      FormdbHttp.QueryCache,
      # Start a worker by calling: FormdbHttp.Worker.start_link(arg)
      # {FormdbHttp.Worker, arg},
      # Start to serve requests, typically the last entry
      FormdbHttpWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FormdbHttp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FormdbHttpWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
