# SPDX-License-Identifier: PMPL-1.0-or-later
# FormDB HTTP API Router

defmodule FormdbHttpWeb.Router do
  use FormdbHttpWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", FormdbHttpWeb do
    pipe_through :api

    # Core API
    get "/version", ApiController, :version

    # Database operations
    post "/databases", ApiController, :create_database
    delete "/databases/:db_id", ApiController, :delete_database

    # Transaction operations
    post "/databases/:db_id/transactions", ApiController, :begin_transaction
    post "/transactions/:txn_id/commit", ApiController, :commit_transaction
    post "/transactions/:txn_id/abort", ApiController, :abort_transaction
    post "/transactions/:txn_id/operations", ApiController, :apply_operation

    # Schema and journal
    get "/databases/:db_id/schema", ApiController, :get_schema
    get "/databases/:db_id/journal", ApiController, :get_journal

    # FormBD-Geo endpoints
    post "/geo/insert", GeoController, :insert
    get "/geo/query", GeoController, :query
    get "/geo/features/:feature_id/provenance", GeoController, :provenance

    # FormBD-Analytics endpoints
    post "/analytics/timeseries", AnalyticsController, :insert
    get "/analytics/timeseries", AnalyticsController, :query
    get "/analytics/timeseries/:series_id/provenance", AnalyticsController, :provenance
  end
end
