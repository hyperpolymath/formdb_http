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
    alias FormdbHttp.{FormDB, CBOR, SpatialIndex, QueryCache}

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
            # Update spatial index
            case extract_bbox(geometry) do
              {:ok, bbox} ->
                db_id = extract_db_id(db_handle)
                SpatialIndex.insert(db_id, feature_id, bbox)

              :error ->
                :ok
            end

            # Invalidate query cache for this database
            db_id = extract_db_id(db_handle)
            QueryCache.invalidate_db(db_id)

            # Publish to PubSub for real-time subscribers
            Phoenix.PubSub.broadcast(
              FormdbHttp.PubSub,
              "journal:#{db_id}",
              {:journal_event, feature}
            )

            {:ok, %{feature_id: feature_id, block_id: block_id}}

          {:ok, block_id} when is_binary(block_id) ->
            # Update spatial index
            case extract_bbox(geometry) do
              {:ok, bbox} ->
                db_id = extract_db_id(db_handle)
                SpatialIndex.insert(db_id, feature_id, bbox)

              :error ->
                :ok
            end

            # Invalidate cache and publish event
            db_id = extract_db_id(db_handle)
            QueryCache.invalidate_db(db_id)

            Phoenix.PubSub.broadcast(
              FormdbHttp.PubSub,
              "journal:#{db_id}",
              {:journal_event, feature}
            )

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
  def query_by_bbox(db_handle, {minx, miny, maxx, maxy} = bbox, filters) do
    alias FormdbHttp.{FormDB, CBOR, SpatialIndex, QueryCache}

    db_id = extract_db_id(db_handle)
    limit = Map.get(filters, :limit, 100)

    # Generate cache key
    cache_key = QueryCache.query_key(db_id, :geo_bbox, %{bbox: bbox, limit: limit})

    # Check cache first
    case QueryCache.get(cache_key) do
      {:ok, cached_result} ->
        {:ok, cached_result}

      :miss ->
        # Use spatial index if available
        result =
          case SpatialIndex.query(db_id, bbox) do
            {:ok, [_ | _] = feature_ids} ->
              # M13: Use spatial index to get feature IDs, then fetch features
              features = fetch_features_by_ids(db_handle, feature_ids, limit)

              %{
                type: "FeatureCollection",
                bbox: [minx, miny, maxx, maxy],
                features: features
              }

            {:ok, []} ->
              # Index returned no results
              %{
                type: "FeatureCollection",
                bbox: [minx, miny, maxx, maxy],
                features: []
              }

            {:error, :index_not_found} ->
              # Fall back to linear scan (M12 behavior)
              linear_scan_bbox(db_handle, bbox, limit)
          end

        # Cache the result
        QueryCache.put(cache_key, result)

        {:ok, result}
    end
  end

  defp linear_scan_bbox(db_handle, {minx, miny, maxx, maxy} = bbox, limit) do
    alias FormdbHttp.{FormDB, CBOR}

    case FormDB.get_journal(db_handle, 0) do
      {:ok, journal_cbor} ->
        features =
          case CBOR.decode(journal_cbor) do
            {:ok, journal_entries} when is_list(journal_entries) ->
              journal_entries
              |> Enum.filter(&is_feature?/1)
              |> Enum.filter(&bbox_intersects?(&1, bbox))
              |> Enum.take(limit)

            {:ok, _} ->
              []

            {:error, _} ->
              []
          end

        %{
          type: "FeatureCollection",
          bbox: [minx, miny, maxx, maxy],
          features: features
        }

      {:error, _} ->
        %{
          type: "FeatureCollection",
          bbox: [minx, miny, maxx, maxy],
          features: []
        }
    end
  end

  defp fetch_features_by_ids(db_handle, feature_ids, limit) do
    alias FormdbHttp.{FormDB, CBOR}

    # Fetch journal and filter by IDs
    case FormDB.get_journal(db_handle, 0) do
      {:ok, journal_cbor} ->
        case CBOR.decode(journal_cbor) do
          {:ok, journal_entries} when is_list(journal_entries) ->
            id_set = MapSet.new(feature_ids)

            journal_entries
            |> Enum.filter(fn entry ->
              is_feature?(entry) and MapSet.member?(id_set, Map.get(entry, "id"))
            end)
            |> Enum.take(limit)

          _ ->
            []
        end

      _ ->
        []
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

  defp generate_feature_id do
    "feat_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  # Helper functions for querying

  defp is_feature?(%{"type" => "Feature"}), do: true
  defp is_feature?(_), do: false

  @doc """
  Check if a feature's geometry intersects with a bounding box.
  """
  def bbox_intersects?(%{"geometry" => geometry}, {minx, miny, maxx, maxy}) do
    case extract_bbox(geometry) do
      {:ok, {fminx, fminy, fmaxx, fmaxy}} ->
        # Check if bboxes intersect
        not (fmaxx < minx or fminx > maxx or fmaxy < miny or fminy > maxy)

      :error ->
        false
    end
  end

  def bbox_intersects?(_, _), do: false

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

  defp extract_db_id(db_handle) when is_reference(db_handle) do
    # Extract database ID from handle reference
    # For M13 PoC, use inspect to get a stable ID
    inspect(db_handle)
  end

  defp extract_db_id(_), do: "unknown"
end
