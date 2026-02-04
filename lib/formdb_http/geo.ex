# SPDX-License-Identifier: PMPL-1.0-or-later
# FormBD-Geo - Geospatial operations with provenance

defmodule FormdbHttp.Geo do
  @moduledoc """
  Geospatial data operations with provenance tracking.
  Handles GeoJSON features and spatial queries.
  """

  @type geometry :: %{
          type: String.t(),
          coordinates: list()
        }

  @type feature :: %{
          type: String.t(),
          id: String.t(),
          geometry: geometry(),
          properties: map(),
          provenance: map()
        }

  @type bbox :: {float(), float(), float(), float()}

  @doc """
  Insert a geospatial feature with provenance.
  Returns feature ID and block ID.
  """
  @spec insert_feature(reference(), geometry(), map(), map()) ::
          {:ok, %{feature_id: String.t(), block_id: binary()}} | {:error, term()}
  def insert_feature(db_handle, geometry, properties, provenance) do
    # Create GeoJSON feature
    feature = %{
      type: "Feature",
      geometry: geometry,
      properties: properties,
      provenance: provenance
    }

    # Encode as CBOR
    cbor_data = encode_to_cbor(feature)

    # Store in database (M10 PoC just validates)
    feature_id = generate_feature_id()

    {:ok, %{feature_id: feature_id, block_id: <<0, 0, 0, 0, 0, 0, 0, 1>>}}
  end

  @doc """
  Query features by bounding box.
  Returns GeoJSON FeatureCollection.
  """
  @spec query_by_bbox(reference(), bbox(), map()) ::
          {:ok, map()} | {:error, term()}
  def query_by_bbox(_db_handle, {minx, miny, maxx, maxy}, _filters) do
    # M10 PoC: Return empty FeatureCollection
    # M11+: Query spatial index

    {:ok,
     %{
       type: "FeatureCollection",
       bbox: [minx, miny, maxx, maxy],
       features: []
     }}
  end

  @doc """
  Query features by geometry intersection.
  """
  @spec query_by_geometry(reference(), geometry(), map()) ::
          {:ok, map()} | {:error, term()}
  def query_by_geometry(_db_handle, _geometry, _filters) do
    # M10 PoC: Return empty FeatureCollection
    {:ok,
     %{
       type: "FeatureCollection",
       features: []
     }}
  end

  @doc """
  Get provenance history for a feature.
  """
  @spec get_feature_provenance(reference(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_feature_provenance(_db_handle, feature_id) do
    # M10 PoC: Return dummy provenance chain
    {:ok,
     %{
       feature_id: feature_id,
       provenance_chain: [
         %{
           block_id: Base.encode64(<<0, 0, 0, 0, 0, 0, 0, 1>>),
           timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
           source: "insert",
           operation: "create"
         }
       ]
     }}
  end

  @doc """
  Validate GeoJSON geometry.
  """
  @spec validate_geometry(map()) :: :ok | {:error, String.t()}
  def validate_geometry(%{"type" => type, "coordinates" => coords})
      when type in ["Point", "LineString", "Polygon", "MultiPoint", "MultiLineString", "MultiPolygon"] do
    case validate_coordinates(type, coords) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  def validate_geometry(_), do: {:error, "Invalid geometry: missing type or coordinates"}

  # ============================================================
  # Private Functions
  # ============================================================

  defp validate_coordinates("Point", coords) when is_list(coords) and length(coords) == 2 do
    if Enum.all?(coords, &is_number/1) do
      :ok
    else
      {:error, "Point coordinates must be numbers"}
    end
  end

  defp validate_coordinates("LineString", coords) when is_list(coords) do
    if length(coords) >= 2 do
      :ok
    else
      {:error, "LineString must have at least 2 positions"}
    end
  end

  defp validate_coordinates("Polygon", coords) when is_list(coords) do
    if length(coords) >= 1 do
      :ok
    else
      {:error, "Polygon must have at least 1 ring"}
    end
  end

  defp validate_coordinates(_, _), do: :ok

  defp encode_to_cbor(data) do
    # M10 PoC: Simple JSON encoding, M11+ will use actual CBOR
    Jason.encode!(data)
  end

  defp generate_feature_id do
    "feat_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
