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
    alias FormdbHttp.{FormDB, CBOR}

    # Generate unique feature ID
    feature_id = generate_feature_id()

    # Create GeoJSON feature with metadata
    feature = %{
      type: "Feature",
      id: feature_id,
      geometry: geometry,
      properties: properties,
      provenance: provenance,
      stored_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Encode as CBOR
    case CBOR.encode(feature) do
      {:ok, cbor_data} ->
        # Store in database via transaction
        case FormDB.with_transaction(db_handle, :read_write, fn txn ->
               FormDB.apply_operation(txn, cbor_data)
             end) do
          {:ok, {:ok, block_id}} ->
            {:ok, %{feature_id: feature_id, block_id: block_id}}

          {:ok, block_id} when is_binary(block_id) ->
            {:ok, %{feature_id: feature_id, block_id: block_id}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:cbor_encode_failed, reason}}
    end
  end

  @doc """
  Query features by bounding box.
  Returns GeoJSON FeatureCollection.
  """
  @spec query_by_bbox(reference(), bbox(), map()) ::
          {:ok, map()} | {:error, term()}
  def query_by_bbox(db_handle, {minx, miny, maxx, maxy}, filters) do
    alias FormdbHttp.{FormDB, CBOR}

    # M12: Linear scan through journal (no spatial index yet)
    # M13+: Use R-tree spatial index for efficient queries

    case FormDB.get_journal(db_handle, 0) do
      {:ok, journal_cbor} ->
        features =
          case CBOR.decode(journal_cbor) do
            {:ok, journal_entries} when is_list(journal_entries) ->
              journal_entries
              |> Enum.filter(&is_feature?/1)
              |> Enum.filter(&bbox_intersects?(&1, {minx, miny, maxx, maxy}))
              |> Enum.take(Map.get(filters, :limit, 100))

            {:ok, _} ->
              []

            {:error, _} ->
              []
          end

        {:ok,
         %{
           type: "FeatureCollection",
           bbox: [minx, miny, maxx, maxy],
           features: features
         }}

      {:error, reason} ->
        {:error, reason}
    end
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

  # Helper functions for querying

  defp is_feature?(%{"type" => "Feature"}), do: true
  defp is_feature?(_), do: false

  defp bbox_intersects?(%{"geometry" => geometry}, {minx, miny, maxx, maxy}) do
    case extract_bbox(geometry) do
      {:ok, {fminx, fminy, fmaxx, fmaxy}} ->
        # Check if bboxes intersect
        not (fmaxx < minx or fminx > maxx or fmaxy < miny or fminy > maxy)

      :error ->
        false
    end
  end

  defp bbox_intersects?(_, _), do: false

  defp extract_bbox(%{"type" => "Point", "coordinates" => [x, y]}) when is_number(x) and is_number(y) do
    {:ok, {x, y, x, y}}
  end

  defp extract_bbox(%{"type" => "LineString", "coordinates" => coords}) when is_list(coords) do
    compute_bbox(coords)
  end

  defp extract_bbox(%{"type" => "Polygon", "coordinates" => [ring | _]}) when is_list(ring) do
    compute_bbox(ring)
  end

  defp extract_bbox(_), do: :error

  defp compute_bbox(coords) when is_list(coords) do
    case coords do
      [] ->
        :error

      [[x, y] | _rest] ->
        {minx, miny, maxx, maxy} =
          Enum.reduce(coords, {x, y, x, y}, fn
            [cx, cy], {min_x, min_y, max_x, max_y} ->
              {min(cx, min_x), min(cy, min_y), max(cx, max_x), max(cy, max_y)}

            _, acc ->
              acc
          end)

        {:ok, {minx, miny, maxx, maxy}}

      _ ->
        :error
    end
  end
end
