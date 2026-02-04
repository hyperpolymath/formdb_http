# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule FormdbHttpWeb.Plugs.RateLimiter do
  @moduledoc """
  Rate limiting middleware for HTTP API.

  Implements token bucket algorithm using ETS for fast in-memory tracking.

  Features:
  - Per-IP rate limiting
  - Per-user rate limiting (if authenticated)
  - Configurable limits and windows
  - Standard rate limit headers (X-RateLimit-*)

  Configuration:
  - rate_limit_enabled: Enable/disable rate limiting (default: false)
  - rate_limit_per_minute: Requests per minute (default: 60)
  - rate_limit_burst: Burst allowance (default: 10)

  Headers returned:
  - X-RateLimit-Limit: Maximum requests per window
  - X-RateLimit-Remaining: Remaining requests in current window
  - X-RateLimit-Reset: Unix timestamp when window resets
  - Retry-After: Seconds until next request allowed (when rate limited)
  """

  import Plug.Conn
  import Phoenix.Controller

  @behaviour Plug

  @table_name :rate_limit_buckets
  @cleanup_interval 60_000  # Clean up stale entries every 60 seconds

  def init(opts) do
    opts
    |> Keyword.put_new(:rate_limit_enabled, false)  # Disabled by default
    |> Keyword.put_new(:rate_limit_per_minute, 60)
    |> Keyword.put_new(:rate_limit_burst, 10)
    |> Keyword.put_new(:window_seconds, 60)
  end

  def call(conn, opts) do
    rate_limit_enabled = Keyword.get(opts, :rate_limit_enabled)

    if rate_limit_enabled do
      check_rate_limit(conn, opts)
    else
      conn
    end
  end

  @doc """
  Initialize the rate limiter ETS table.
  Called by the application supervisor.
  """
  def start_link(_opts) do
    :ets.new(@table_name, [:named_table, :public, :set, {:write_concurrency, true}])

    # Start cleanup process
    pid = spawn_link(fn -> cleanup_loop() end)
    {:ok, pid}
  end

  defp check_rate_limit(conn, opts) do
    limit = Keyword.get(opts, :rate_limit_per_minute)
    burst = Keyword.get(opts, :rate_limit_burst)
    window_seconds = Keyword.get(opts, :window_seconds)

    identifier = get_identifier(conn)
    now = System.system_time(:second)

    case check_and_update_bucket(identifier, now, limit, burst, window_seconds) do
      {:ok, remaining, reset_at} ->
        conn
        |> put_rate_limit_headers(limit, remaining, reset_at)

      {:error, :rate_limit_exceeded, reset_at} ->
        retry_after = reset_at - now

        conn
        |> put_status(:too_many_requests)
        |> put_rate_limit_headers(limit, 0, reset_at)
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_view(json: FormdbHttpWeb.ErrorJSON)
        |> render(:"429", %{
          message: "Rate limit exceeded",
          retry_after: retry_after
        })
        |> halt()
    end
  end

  defp get_identifier(conn) do
    # Use user ID if authenticated, otherwise use IP
    case Map.get(conn.assigns, :user_id) do
      nil ->
        {:ip, format_ip(conn.remote_ip)}
      user_id ->
        {:user, user_id}
    end
  end

  defp check_and_update_bucket(identifier, now, limit, burst, window_seconds) do
    # Get or create bucket
    case :ets.lookup(@table_name, identifier) do
      [] ->
        # New bucket
        bucket = {identifier, now, limit + burst - 1, now + window_seconds}
        :ets.insert(@table_name, bucket)
        {:ok, limit + burst - 1, now + window_seconds}

      [{_id, last_check, tokens, reset_at}] ->
        if now >= reset_at do
          # Window expired, reset bucket
          new_bucket = {identifier, now, limit + burst - 1, now + window_seconds}
          :ets.insert(@table_name, new_bucket)
          {:ok, limit + burst - 1, now + window_seconds}
        else
          # Calculate tokens refilled since last check
          elapsed = now - last_check
          refill_rate = limit / window_seconds
          tokens_to_add = floor(elapsed * refill_rate)
          new_tokens = min(tokens + tokens_to_add, limit + burst)

          if new_tokens >= 1 do
            # Allow request, consume 1 token
            updated_bucket = {identifier, now, new_tokens - 1, reset_at}
            :ets.insert(@table_name, updated_bucket)
            {:ok, floor(new_tokens - 1), reset_at}
          else
            # Rate limit exceeded
            {:error, :rate_limit_exceeded, reset_at}
          end
        end
    end
  end

  defp put_rate_limit_headers(conn, limit, remaining, reset_at) do
    conn
    |> put_resp_header("x-ratelimit-limit", to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", to_string(remaining))
    |> put_resp_header("x-ratelimit-reset", to_string(reset_at))
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}) do
    "#{Integer.to_string(a, 16)}:#{Integer.to_string(b, 16)}:#{Integer.to_string(c, 16)}:#{Integer.to_string(d, 16)}:#{Integer.to_string(e, 16)}:#{Integer.to_string(f, 16)}:#{Integer.to_string(g, 16)}:#{Integer.to_string(h, 16)}"
  end
  defp format_ip(_), do: "unknown"

  # Cleanup loop to remove stale entries
  defp cleanup_loop do
    Process.sleep(@cleanup_interval)

    now = System.system_time(:second)

    # Remove buckets that expired more than 5 minutes ago
    cutoff = now - 300

    :ets.select_delete(@table_name, [
      {{:_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])

    cleanup_loop()
  end
end
