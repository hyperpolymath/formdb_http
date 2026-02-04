# SPDX-License-Identifier: PMPL-1.0-or-later
# FormDB NIF - Elixir wrapper for Rustler NIF
# This module delegates to the Erlang formdb_nif module

defmodule FormdbNif do
  @moduledoc """
  Elixir wrapper for FormDB Rustler NIF.
  Provides low-level access to FormDB operations.
  Delegates to the Erlang :formdb_nif module.
  """

  # Ensure the Erlang module is compiled first
  # The actual NIF loading happens in the Erlang module

  @doc "Get FormDB version as {major, minor, patch}"
  def version, do: :formdb_nif.version()

  @doc "Open a database connection"
  def db_open(path), do: :formdb_nif.db_open(path)

  @doc "Close a database connection"
  def db_close(db_handle), do: :formdb_nif.db_close(db_handle)

  @doc "Begin a transaction (mode: 'read_only' or 'read_write')"
  def txn_begin(db_handle, mode), do: :formdb_nif.txn_begin(db_handle, mode)

  @doc "Commit a transaction"
  def txn_commit(txn_handle), do: :formdb_nif.txn_commit(txn_handle)

  @doc "Abort a transaction"
  def txn_abort(txn_handle), do: :formdb_nif.txn_abort(txn_handle)

  @doc "Apply a CBOR operation within a transaction"
  def apply(txn_handle, cbor_binary), do: :formdb_nif.apply(txn_handle, cbor_binary)

  @doc "Get database schema (CBOR-encoded)"
  def schema(db_handle), do: :formdb_nif.schema(db_handle)

  @doc "Get journal entries since a sequence number (CBOR-encoded)"
  def journal(db_handle, since), do: :formdb_nif.journal(db_handle, since)
end
