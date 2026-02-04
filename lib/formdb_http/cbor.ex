# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule FormdbHttp.CBOR do
  @moduledoc """
  CBOR (RFC 8949) encoding and decoding for FormDB operations.

  Provides simple CBOR encoding/decoding for FormDB data structures.
  Supports:
  - Maps/objects
  - Arrays
  - Strings
  - Numbers
  - Booleans
  - Null

  For production, consider using the 'cbor' package from Hex.
  This is a minimal implementation for M12 PoC.
  """

  @doc """
  Encode an Elixir term to CBOR binary.
  """
  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(term) do
    try do
      {:ok, do_encode(term)}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Decode a CBOR binary to an Elixir term.
  """
  @spec decode(binary() | list()) :: {:ok, term()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    try do
      {value, _rest} = do_decode(binary)
      {:ok, value}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  def decode(list) when is_list(list) do
    # Convert list to binary and decode
    decode(:binary.list_to_bin(list))
  end

  # Encoding implementation

  defp do_encode(value) when is_map(value) do
    # Major type 5: map
    entries = Map.to_list(value)
    count = length(entries)

    header = encode_map_header(count)

    body =
      entries
      |> Enum.map(fn {k, v} ->
        do_encode(to_string(k)) <> do_encode(v)
      end)
      |> Enum.join()

    header <> body
  end

  defp do_encode(value) when is_list(value) do
    # Major type 4: array
    count = length(value)
    header = encode_array_header(count)

    body =
      value
      |> Enum.map(&do_encode/1)
      |> Enum.join()

    header <> body
  end

  defp do_encode(value) when is_binary(value) do
    # Major type 3: text string
    byte_length = byte_size(value)
    encode_string_header(byte_length) <> value
  end

  defp do_encode(value) when is_integer(value) and value >= 0 do
    # Major type 0: unsigned integer
    encode_uint(value)
  end

  defp do_encode(value) when is_integer(value) and value < 0 do
    # Major type 1: negative integer
    encode_negint(value)
  end

  defp do_encode(value) when is_float(value) do
    # Major type 7: float64
    <<0xFB, value::float-64>>
  end

  defp do_encode(true), do: <<0xF5>>
  defp do_encode(false), do: <<0xF4>>
  defp do_encode(nil), do: <<0xF6>>

  defp encode_uint(value) when value < 24, do: <<value>>
  defp encode_uint(value) when value < 256, do: <<0x18, value>>
  defp encode_uint(value) when value < 65536, do: <<0x19, value::16>>
  defp encode_uint(value) when value < 4_294_967_296, do: <<0x1A, value::32>>
  defp encode_uint(value), do: <<0x1B, value::64>>

  defp encode_negint(value) do
    # Encode as -1 - n
    abs_minus_1 = abs(value) - 1
    major_type_1 = 0x20

    cond do
      abs_minus_1 < 24 -> <<major_type_1 + abs_minus_1>>
      abs_minus_1 < 256 -> <<0x38, abs_minus_1>>
      abs_minus_1 < 65536 -> <<0x39, abs_minus_1::16>>
      abs_minus_1 < 4_294_967_296 -> <<0x3A, abs_minus_1::32>>
      true -> <<0x3B, abs_minus_1::64>>
    end
  end

  defp encode_string_header(length) when length < 24, do: <<0x60 + length>>
  defp encode_string_header(length) when length < 256, do: <<0x78, length>>
  defp encode_string_header(length) when length < 65536, do: <<0x79, length::16>>
  defp encode_string_header(length) when length < 4_294_967_296, do: <<0x7A, length::32>>
  defp encode_string_header(length), do: <<0x7B, length::64>>

  defp encode_array_header(count) when count < 24, do: <<0x80 + count>>
  defp encode_array_header(count) when count < 256, do: <<0x98, count>>
  defp encode_array_header(count) when count < 65536, do: <<0x99, count::16>>
  defp encode_array_header(count) when count < 4_294_967_296, do: <<0x9A, count::32>>
  defp encode_array_header(count), do: <<0x9B, count::64>>

  defp encode_map_header(count) when count < 24, do: <<0xA0 + count>>
  defp encode_map_header(count) when count < 256, do: <<0xB8, count>>
  defp encode_map_header(count) when count < 65536, do: <<0xB9, count::16>>
  defp encode_map_header(count) when count < 4_294_967_296, do: <<0xBA, count::32>>
  defp encode_map_header(count), do: <<0xBB, count::64>>

  # Decoding implementation (simplified)

  defp do_decode(<<major_type::3, additional::5, rest::binary>>) do
    case major_type do
      0 -> decode_uint(additional, rest)
      1 -> decode_negint(additional, rest)
      2 -> decode_bytes(additional, rest)
      3 -> decode_string(additional, rest)
      4 -> decode_array(additional, rest)
      5 -> decode_map(additional, rest)
      7 -> decode_simple(additional, rest)
      _ -> raise "Unsupported major type: #{major_type}"
    end
  end

  defp decode_uint(n, rest) when n < 24, do: {n, rest}

  defp decode_uint(24, <<value, rest::binary>>), do: {value, rest}

  defp decode_uint(25, <<value::16, rest::binary>>), do: {value, rest}

  defp decode_uint(26, <<value::32, rest::binary>>), do: {value, rest}

  defp decode_uint(27, <<value::64, rest::binary>>), do: {value, rest}

  defp decode_negint(n, rest) when n < 24, do: {-1 - n, rest}
  defp decode_negint(24, <<value, rest::binary>>), do: {-1 - value, rest}
  defp decode_negint(25, <<value::16, rest::binary>>), do: {-1 - value, rest}
  defp decode_negint(26, <<value::32, rest::binary>>), do: {-1 - value, rest}
  defp decode_negint(27, <<value::64, rest::binary>>), do: {-1 - value, rest}

  defp decode_bytes(n, rest) when n < 24 do
    <<bytes::binary-size(n), rest2::binary>> = rest
    {bytes, rest2}
  end

  defp decode_bytes(24, <<length, rest::binary>>) do
    <<bytes::binary-size(length), rest2::binary>> = rest
    {bytes, rest2}
  end

  defp decode_string(n, rest) when n < 24 do
    <<string::binary-size(n), rest2::binary>> = rest
    {string, rest2}
  end

  defp decode_string(24, <<length, rest::binary>>) do
    <<string::binary-size(length), rest2::binary>> = rest
    {string, rest2}
  end

  defp decode_string(25, <<length::16, rest::binary>>) do
    <<string::binary-size(length), rest2::binary>> = rest
    {string, rest2}
  end

  defp decode_array(n, rest) when n < 24 do
    decode_array_items(n, rest, [])
  end

  defp decode_array(24, <<count, rest::binary>>) do
    decode_array_items(count, rest, [])
  end

  defp decode_array_items(0, rest, acc), do: {Enum.reverse(acc), rest}

  defp decode_array_items(count, rest, acc) do
    {item, rest2} = do_decode(rest)
    decode_array_items(count - 1, rest2, [item | acc])
  end

  defp decode_map(n, rest) when n < 24 do
    decode_map_items(n, rest, %{})
  end

  defp decode_map(24, <<count, rest::binary>>) do
    decode_map_items(count, rest, %{})
  end

  defp decode_map_items(0, rest, acc), do: {acc, rest}

  defp decode_map_items(count, rest, acc) do
    {key, rest2} = do_decode(rest)
    {value, rest3} = do_decode(rest2)
    decode_map_items(count - 1, rest3, Map.put(acc, key, value))
  end

  defp decode_simple(20, rest), do: {false, rest}
  defp decode_simple(21, rest), do: {true, rest}
  defp decode_simple(22, rest), do: {nil, rest}

  defp decode_simple(27, <<value::float-64, rest::binary>>), do: {value, rest}
end
