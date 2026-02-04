# SPDX-License-Identifier: PMPL-1.0-or-later
# FormDB Client - High-level Elixir API

defmodule FormdbHttp.FormDB do
  @moduledoc """
  High-level FormDB client API for Elixir.
  Wraps the Rustler NIF with idiomatic Elixir interfaces.
  """

  alias FormdbNif

  @type db_handle :: reference()
  @type txn_handle :: reference()
  @type error :: {:error, atom() | String.t()}

  # ============================================================
  # Public API
  # ============================================================

  @doc "Get FormDB version"
  @spec version() :: {integer(), integer(), integer()}
  def version do
    FormdbNif.version()
  end

  @doc "Open a database connection"
  @spec connect(String.t()) :: {:ok, db_handle()} | error()
  def connect(path) when is_binary(path) do
    handle = FormdbNif.db_open(path)
    {:ok, handle}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Close a database connection"
  @spec disconnect(db_handle()) :: :ok | error()
  def disconnect(db_handle) do
    FormdbNif.db_close(db_handle)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Begin a transaction"
  @spec begin_transaction(db_handle(), :read_only | :read_write) ::
          {:ok, txn_handle()} | error()
  def begin_transaction(db_handle, mode) when mode in [:read_only, :read_write] do
    mode_binary = Atom.to_string(mode)

    case FormdbNif.txn_begin(db_handle, mode_binary) do
      {:ok, txn_handle} -> {:ok, txn_handle}
      {:error, reason} -> {:error, reason}
      txn_handle when is_reference(txn_handle) -> {:ok, txn_handle}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Commit a transaction"
  @spec commit(txn_handle()) :: :ok | error()
  def commit(txn_handle) do
    FormdbNif.txn_commit(txn_handle)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Abort a transaction"
  @spec abort(txn_handle()) :: :ok | error()
  def abort(txn_handle) do
    FormdbNif.txn_abort(txn_handle)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Apply a CBOR operation within a transaction.
  Returns the block ID as a binary.
  """
  @spec apply_operation(txn_handle(), binary()) :: {:ok, binary()} | error()
  def apply_operation(txn_handle, cbor_binary) when is_binary(cbor_binary) do
    case FormdbNif.apply(txn_handle, cbor_binary) do
      {:ok, block_id} -> {:ok, block_id}
      {:error, reason} -> {:error, reason}
      block_id when is_binary(block_id) -> {:ok, block_id}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Get database schema (CBOR-encoded)"
  @spec get_schema(db_handle()) :: {:ok, binary()} | error()
  def get_schema(db_handle) do
    schema = FormdbNif.schema(db_handle)
    {:ok, schema}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Get journal entries since a sequence number (CBOR-encoded)"
  @spec get_journal(db_handle(), integer()) :: {:ok, binary()} | error()
  def get_journal(db_handle, since) when is_integer(since) do
    journal = FormdbNif.journal(db_handle, since)
    {:ok, journal}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Execute a function within a transaction with automatic commit/abort.

  ## Example

      FormDB.with_transaction(db, :read_write, fn txn ->
        FormDB.apply_operation(txn, cbor_data)
      end)
  """
  @spec with_transaction(db_handle(), :read_only | :read_write, (txn_handle() -> any())) ::
          {:ok, any()} | error()
  def with_transaction(db_handle, mode, fun) when is_function(fun, 1) do
    case begin_transaction(db_handle, mode) do
      {:ok, txn} ->
        try do
          result = fun.(txn)

          case commit(txn) do
            :ok -> {:ok, result}
            {:error, _} = err ->
              abort(txn)
              err
          end
        rescue
          e ->
            abort(txn)
            {:error, Exception.message(e)}
        end

      {:error, _} = err ->
        err
    end
  end
end
