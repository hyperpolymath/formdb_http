# SPDX-License-Identifier: PMPL-1.0-or-later
# FormBD-Geo HTTP Controller

defmodule FormdbHttpWeb.GeoController do
  use FormdbHttpWeb, :controller

  alias FormdbHttp.{Geo, DatabaseRegistry}

  @doc "POST /api/v1/databases/:db_id/features - Insert geospatial feature"
  def insert(conn, %{"db_id" => db_id} = params) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        with {:ok, geometry} <- get_param(params, "geometry"),
             :ok <- Geo.validate_geometry(geometry) do
          properties = Map.get(params, "properties", %{})
          provenance = Map.get(params, "provenance", %{})

          case Geo.insert_feature(db_handle, geometry, properties, provenance) do
            {:ok, %{feature_id: feature_id, block_id: block_id}} ->
              # Convert block_id to binary if it's a list
              block_id_binary = if is_list(block_id), do: :binary.list_to_bin(block_id), else: block_id

              json(conn, %{
                feature_id: feature_id,
                block_id: Base.encode64(block_id_binary),
                stored_at: DateTime.utc_now() |> DateTime.to_iso8601()
              })

            {:error, reason} ->
              conn
              |> put_status(:internal_server_error)
              |> json(%{error: %{code: "INSERT_FAILED", message: to_string(reason)}})
          end
        else
          {:error, field} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: %{code: "INVALID_REQUEST", message: "Missing or invalid field: #{field}"}})
        end
    end
  end

  @doc "GET /api/v1/databases/:db_id/features/bbox - Query by bounding box"
  def query_bbox(conn, %{"db_id" => db_id} = params) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        with {:ok, minx} <- parse_float(params, "minx"),
             {:ok, miny} <- parse_float(params, "miny"),
             {:ok, maxx} <- parse_float(params, "maxx"),
             {:ok, maxy} <- parse_float(params, "maxy") do
          bbox = {minx, miny, maxx, maxy}
          limit = parse_int(Map.get(params, "limit", "100"), 100)
          filters = %{limit: limit}

          case Geo.query_by_bbox(db_handle, bbox, filters) do
            {:ok, feature_collection} ->
              json(conn, feature_collection)

            # M10 PoC: Error clause unreachable (always returns {:ok, ...})
            # {:error, reason} ->
            #   conn
            #   |> put_status(:internal_server_error)
            #   |> json(%{error: %{code: "QUERY_FAILED", message: to_string(reason)}})
          end
        else
          {:error, field} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: %{code: "INVALID_REQUEST", message: "Missing or invalid field: #{field}"}})
        end
    end
  end

  @doc "GET /api/v1/databases/:db_id/features/geometry - Query by geometry"
  def query_geometry(conn, %{"db_id" => db_id} = params) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        with {:ok, geometry} <- get_param(params, "geometry"),
             :ok <- Geo.validate_geometry(geometry) do
          limit = parse_int(Map.get(params, "limit", "100"), 100)
          filters = %{limit: limit}

          case Geo.query_by_geometry(db_handle, geometry, filters) do
            {:ok, feature_collection} ->
              json(conn, feature_collection)

            # M10 PoC: Error clause unreachable (always returns {:ok, ...})
            # {:error, reason} ->
            #   conn
            #   |> put_status(:internal_server_error)
            #   |> json(%{error: %{code: "QUERY_FAILED", message: to_string(reason)}})
          end
        else
          {:error, field} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: %{code: "INVALID_REQUEST", message: "Missing or invalid field: #{field}"}})
        end
    end
  end

  @doc "GET /api/v1/databases/:db_id/features/:feature_id - Get feature by ID"
  def get_feature(conn, %{"db_id" => db_id, "feature_id" => feature_id}) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      _db_handle ->
        # M13 PoC: Return dummy feature
        # In production, this would fetch from journal by feature_id
        json(conn, %{
          type: "Feature",
          id: feature_id,
          geometry: %{type: "Point", coordinates: [0.0, 0.0]},
          properties: %{},
          provenance: %{}
        })
    end
  end

  @doc "GET /api/v1/databases/:db_id/features/:feature_id/provenance - Get feature provenance"
  def provenance(conn, %{"db_id" => db_id, "feature_id" => feature_id}) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        case Geo.get_feature_provenance(db_handle, feature_id) do
          {:ok, provenance_data} ->
            json(conn, provenance_data)

          # M10 PoC: Error clause unreachable (always returns {:ok, ...})
          # {:error, reason} ->
          #   conn
          #   |> put_status(:internal_server_error)
          #   |> json(%{error: %{code: "PROVENANCE_FAILED", message: to_string(reason)}})
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

  defp parse_float(params, key) do
    case Map.get(params, key) do
      nil -> {:error, key}
      value when is_binary(value) ->
        case Float.parse(value) do
          {f, _} -> {:ok, f}
          :error -> {:error, key}
        end
      value when is_number(value) -> {:ok, value * 1.0}
    end
  end

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(n, _default) when is_integer(n), do: n
  defp parse_int(_, default), do: default
end
