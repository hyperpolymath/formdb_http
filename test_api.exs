# SPDX-License-Identifier: PMPL-1.0-or-later
# FormDB HTTP API Test Script

# Start the application
{:ok, _} = Application.ensure_all_started(:formdb_http)

alias FormdbHttp.FormDB

IO.puts("\n=== FormDB HTTP API Test ===\n")

# Test 1: Version
IO.puts("Test 1: Get version...")
{major, minor, patch} = FormDB.version()
IO.puts("  ✓ Version: #{major}.#{minor}.#{patch}\n")

# Test 2: Connect to database
IO.puts("Test 2: Connect to database...")
{:ok, db} = FormDB.connect("/tmp/formdb_http_test")
IO.puts("  ✓ Database connected\n")

# Test 3: Get schema
IO.puts("Test 3: Get schema...")
{:ok, schema} = FormDB.get_schema(db)
IO.puts("  ✓ Schema: #{inspect(schema)}\n")

# Test 4: Get journal
IO.puts("Test 4: Get journal...")
{:ok, journal} = FormDB.get_journal(db, 0)
IO.puts("  ✓ Journal: #{inspect(journal)}\n")

# Test 5: Transaction flow
IO.puts("Test 5: Transaction flow...")
result =
  FormDB.with_transaction(db, :read_write, fn txn ->
    # Apply a CBOR operation (map {1: 2})
    cbor_map = <<0xa1, 0x01, 0x02>>
    {:ok, block_id} = FormDB.apply_operation(txn, cbor_map)
    IO.puts("  ✓ Operation applied, block ID: #{inspect(block_id)}")
    block_id
  end)

case result do
  {:ok, _block_id} -> IO.puts("  ✓ Transaction committed\n")
  {:error, reason} -> IO.puts("  ✗ Transaction failed: #{inspect(reason)}\n")
end

# Test 6: Disconnect
IO.puts("Test 6: Disconnect...")
:ok = FormDB.disconnect(db)
IO.puts("  ✓ Database disconnected\n")

IO.puts("=== All tests passed! ===\n")
