# SPDX-License-Identifier: PMPL-1.0-or-later
# FormDB HTTP API Router

defmodule FormdbHttpWeb.Router do
  use FormdbHttpWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug FormdbHttpWeb.Plugs.RequestLogger
  end

  pipeline :api_authenticated do
    plug :accepts, ["json"]
    plug FormdbHttpWeb.Plugs.RequestLogger
    plug FormdbHttpWeb.Plugs.Authenticate, auth_enabled: false  # Set to true to enable auth
    plug FormdbHttpWeb.Plugs.RateLimiter, rate_limit_enabled: false  # Set to true to enable rate limiting
  end

  # Health check and metrics endpoints (outside versioned API)
  scope "/", FormdbHttpWeb do
    pipe_through :api

    get "/health", HealthController, :index
    get "/health/live", HealthController, :live
    get "/health/ready", HealthController, :ready
    get "/health/detailed", HealthController, :detailed

    get "/metrics", MetricsController, :index
  end

  # Authentication endpoints
  scope "/auth", FormdbHttpWeb do
    pipe_through :api

    post "/token", AuthController, :generate_token
    post "/verify", AuthController, :verify_token
  end

  scope "/api/v1", FormdbHttpWeb do
    pipe_through :api

    # Database operations (5 endpoints)
    post "/databases", ApiController, :create_database
    get "/databases/:db_id", ApiController, :get_database
    get "/databases/:db_id/journal", ApiController, :get_journal
    get "/databases/:db_id/blocks/:hash", ApiController, :get_block
    delete "/databases/:db_id", ApiController, :delete_database

    # Geospatial operations (5 endpoints)
    post "/databases/:db_id/features", GeoController, :insert
    get "/databases/:db_id/features/bbox", GeoController, :query_bbox
    get "/databases/:db_id/features/geometry", GeoController, :query_geometry
    get "/databases/:db_id/features/:feature_id", GeoController, :get_feature
    get "/databases/:db_id/features/:feature_id/provenance", GeoController, :provenance

    # Time-series operations (5 endpoints)
    post "/databases/:db_id/timeseries", AnalyticsController, :insert
    get "/databases/:db_id/timeseries/:series_id", AnalyticsController, :query
    get "/databases/:db_id/timeseries/:series_id/aggregate", AnalyticsController, :aggregate
    get "/databases/:db_id/timeseries/:series_id/provenance", AnalyticsController, :provenance
    get "/databases/:db_id/timeseries/:series_id/latest", AnalyticsController, :latest
  end
end
