# SPDX-License-Identifier: PMPL-1.0-or-later
# FormBD-Geo HTTP Controller

defmodule FormdbHttpWeb.GeoController do
  use FormdbHttpWeb, :controller

  alias FormdbHttp.{FormDB, Geo}

  @doc "POST /api/v1/geo/insert - Insert geospatial feature"
  def insert(conn, params) do
    with {:ok, db_id} <- get_param(params, "database_id"),
         {:ok, geometry} <- get_param(params, "geometry"),
         {:ok, _} <- Geo.validate_geometry(geometry),
         db_handle when not is_nil(db_handle) <- Process.get(db_id) do
      properties = Map.get(params, "properties", %{})
      provenance = Map.get(params, "provenance", %{})

      case Geo.insert_feature(db_handle, geometry, properties, provenance) do
        {:ok, %{feature_id: feature_id, block_id: block_id}} ->
          json(conn, %{
            feature_id: feature_id,
            block_id: Base.encode64(block_id)
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

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})
    end
  end

  @doc "GET /api/v1/geo/query - Query geospatial features"
  def query(conn, params) do
    with {:ok, db_id} <- get_param(params, "database_id"),
         db_handle when not is_nil(db_handle) <- Process.get(db_id) do
      limit = Map.get(params, "limit", "100") |> parse_int(100)

      result =
        cond do
          # Query by bounding box
          Map.has_key?(params, "bbox") ->
            case parse_bbox(params["bbox"]) do
              {:ok, bbox} ->
                filters = parse_filters(params)
                Geo.query_by_bbox(db_handle, bbox, filters)

              {:error, _} = err ->
                err
            end

          # Query by geometry
          Map.has_key?(params, "geometry") ->
            geometry = params["geometry"]
            filters = parse_filters(params)

            case Geo.validate_geometry(geometry) do
              :ok -> Geo.query_by_geometry(db_handle, geometry, filters)
              {:error, _} = err -> err
            end

          # No spatial filter
          true ->
            {:ok,
             %{
               type: "FeatureCollection",
               features: []
             }}
        end

      case result do
        {:ok, feature_collection} ->
          # Apply limit
          limited_features =
            feature_collection
            |> Map.get(:features, [])
            |> Enum.take(limit)

          json(conn, Map.put(feature_collection, :features, limited_features))

        {:error, reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: %{code: "QUERY_FAILED", message: to_string(reason)}})
      end
    else
      {:error, field} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "INVALID_REQUEST", message: "Missing field: #{field}"}})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})
    end
  end

  @doc "GET /api/v1/geo/features/:feature_id/provenance - Get feature provenance"
  def provenance(conn, %{"feature_id" => feature_id} = params) do
    with {:ok, db_id} <- get_param(params, "database_id"),
         db_handle when not is_nil(db_handle) <- Process.get(db_id) do
      case Geo.get_feature_provenance(db_handle, feature_id) do
        {:ok, provenance_data} ->
          json(conn, provenance_data)

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: %{code: "PROVENANCE_FAILED", message: to_string(reason)}})
      end
    else
      {:error, field} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "INVALID_REQUEST", message: "Missing field: #{field}"}})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})
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

  defp parse_bbox(bbox_str) when is_binary(bbox_str) do
    case String.split(bbox_str, ",") |> Enum.map(&Float.parse/1) do
      [{minx, ""}, {miny, ""}, {maxx, ""}, {maxy, ""}] ->
        {:ok, {minx, miny, maxx, maxy}}

      _ ->
        {:error, "Invalid bbox format. Expected: minx,miny,maxx,maxy"}
    end
  end

  defp parse_bbox(_), do: {:error, "bbox must be a string"}

  defp parse_filters(params) do
    case Map.get(params, "filter") do
      nil -> %{}
      filter when is_map(filter) -> filter
      _ -> %{}
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
