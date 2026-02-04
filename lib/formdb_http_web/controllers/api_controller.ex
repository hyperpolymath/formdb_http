# SPDX-License-Identifier: PMPL-1.0-or-later
# FormDB HTTP API - Core Controller

defmodule FormdbHttpWeb.ApiController do
  use FormdbHttpWeb, :controller

  alias FormdbHttp.{FormDB, DatabaseRegistry}

  # ============================================================
  # Core Endpoints
  # ============================================================

  @doc "GET /api/v1/version - Get FormDB version"
  def version(conn, _params) do
    {major, minor, patch} = FormDB.version()

    json(conn, %{
      version: "#{major}.#{minor}.#{patch}",
      api_version: "v1"
    })
  end

  @doc "POST /api/v1/databases - Create database"
  def create_database(conn, %{"name" => name} = params) do
    description = Map.get(params, "description", "")

    # Generate path from name (M11: in-memory storage, path is just an identifier)
    # In production, this would map to actual storage location
    path = "/tmp/formdb_#{name}"

    case FormDB.connect(path) do
      {:ok, db_handle} ->
        # Store handle in DatabaseRegistry (persists across HTTP requests)
        db_id = generate_id("db")
        metadata = %{name: name, description: description, path: path}
        DatabaseRegistry.put(db_id, db_handle, metadata)

        json(conn, %{
          db_id: db_id,
          name: name,
          description: description,
          created_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: %{code: "CONNECTION_ERROR", message: to_string(reason)}})
    end
  end

  @doc "POST /api/v1/databases/:db_id/transactions - Begin transaction"
  def begin_transaction(conn, %{"db_id" => db_id} = params) do
    mode = String.to_existing_atom(Map.get(params, "mode", "read_write"))

    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        case FormDB.begin_transaction(db_handle, mode) do
          {:ok, txn_handle} ->
            txn_id = generate_id("txn")
            DatabaseRegistry.put(txn_id, txn_handle)

            json(conn, %{
              transaction_id: txn_id,
              mode: Atom.to_string(mode)
            })

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: %{code: "TRANSACTION_ERROR", message: to_string(reason)}})
        end
    end
  end

  @doc "POST /api/v1/transactions/:txn_id/operations - Apply operation"
  def apply_operation(conn, %{"txn_id" => txn_id, "operation" => operation_base64}) do
    case DatabaseRegistry.get(txn_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Transaction not found"}})

      txn_handle ->
        # Decode base64 CBOR
        with {:ok, cbor_binary} <- Base.decode64(operation_base64),
             {:ok, block_id} <- FormDB.apply_operation(txn_handle, cbor_binary) do
          json(conn, %{
            block_id: Base.encode64(block_id),
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          })
        else
          :error ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: %{code: "INVALID_OPERATION", message: "Invalid base64 encoding"}})

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: %{code: "INVALID_OPERATION", message: to_string(reason)}})
        end
    end
  end

  @doc "POST /api/v1/transactions/:txn_id/commit - Commit transaction"
  def commit_transaction(conn, %{"txn_id" => txn_id}) do
    case DatabaseRegistry.get(txn_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Transaction not found"}})

      txn_handle ->
        case FormDB.commit(txn_handle) do
          :ok ->
            DatabaseRegistry.delete(txn_id)
            json(conn, %{status: "committed"})

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: %{code: "TRANSACTION_ERROR", message: to_string(reason)}})
        end
    end
  end

  @doc "POST /api/v1/transactions/:txn_id/abort - Abort transaction"
  def abort_transaction(conn, %{"txn_id" => txn_id}) do
    case DatabaseRegistry.get(txn_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Transaction not found"}})

      txn_handle ->
        case FormDB.abort(txn_handle) do
          :ok ->
            DatabaseRegistry.delete(txn_id)
            json(conn, %{status: "aborted"})

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: %{code: "TRANSACTION_ERROR", message: to_string(reason)}})
        end
    end
  end

  @doc "GET /api/v1/databases/:db_id/schema - Get schema"
  def get_schema(conn, %{"db_id" => db_id}) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        case FormDB.get_schema(db_handle) do
          {:ok, schema} ->
            json(conn, %{
              schema: Base.encode64(schema),
              version: 1
            })

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: %{code: "CONNECTION_ERROR", message: to_string(reason)}})
        end
    end
  end

  @doc "GET /api/v1/databases/:db_id/journal - Get journal"
  def get_journal(conn, %{"db_id" => db_id} = params) do
    since = Map.get(params, "since", "0") |> String.to_integer()

    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        case FormDB.get_journal(db_handle, since) do
          {:ok, journal} ->
            json(conn, %{
              entries: Base.encode64(journal),
              next_sequence: since + 1
            })

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: %{code: "CONNECTION_ERROR", message: to_string(reason)}})
        end
    end
  end

  @doc "GET /api/v1/databases/:db_id - Get database info"
  def get_database(conn, %{"db_id" => db_id}) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      _db_handle ->
        {:ok, metadata} = DatabaseRegistry.get_metadata(db_id)

        json(conn, %{
          db_id: db_id,
          name: Map.get(metadata, :name),
          description: Map.get(metadata, :description),
          path: Map.get(metadata, :path),
          status: "connected"
        })
    end
  end

  @doc "GET /api/v1/databases/:db_id/blocks/:hash - Get block by hash"
  def get_block(conn, %{"db_id" => db_id, "hash" => hash_base64}) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        with {:ok, hash_binary} <- Base.decode64(hash_base64),
             {:ok, block_data} <- FormDB.get_block(db_handle, hash_binary) do
          json(conn, %{
            hash: hash_base64,
            data: Base.encode64(block_data),
            size: byte_size(block_data)
          })
        else
          :error ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: %{code: "INVALID_HASH", message: "Invalid base64 encoding"}})

          {:error, reason} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: %{code: "BLOCK_NOT_FOUND", message: to_string(reason)}})
        end
    end
  end

  @doc "DELETE /api/v1/databases/:db_id - Close database"
  def delete_database(conn, %{"db_id" => db_id}) do
    case DatabaseRegistry.get(db_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "NOT_FOUND", message: "Database not found"}})

      db_handle ->
        case FormDB.disconnect(db_handle) do
          :ok ->
            DatabaseRegistry.delete(db_id)
            json(conn, %{status: "closed"})

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: %{code: "CONNECTION_ERROR", message: to_string(reason)}})
        end
    end
  end

  # ============================================================
  # Helper Functions
  # ============================================================

  defp generate_id(prefix) do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "#{prefix}_#{random}"
  end
end
