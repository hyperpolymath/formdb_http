# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule FormdbHttpWeb.Plugs.RequestLogger do
  @moduledoc """
  Request logging middleware for HTTP API.

  Logs:
  - Request method and path
  - Response status code
  - Request duration in milliseconds
  - Client IP address
  - User agent (if present)
  - Request ID (if present)

  Example log output:
  [info] GET /api/v1/version - 200 in 2ms (127.0.0.1)
  """

  require Logger
  import Plug.Conn

  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    start_time = System.monotonic_time()

    register_before_send(conn, fn conn ->
      end_time = System.monotonic_time()
      duration_ms = System.convert_time_unit(end_time - start_time, :native, :millisecond)

      log_request(conn, duration_ms)
      conn
    end)
  end

  defp log_request(conn, duration_ms) do
    method = conn.method
    path = conn.request_path
    status = conn.status
    remote_ip = format_ip(conn.remote_ip)
    user_agent = get_user_agent(conn)
    request_id = get_request_id(conn)

    metadata = [
      method: method,
      path: path,
      status: status,
      duration_ms: duration_ms,
      remote_ip: remote_ip,
      user_agent: user_agent,
      request_id: request_id
    ]

    level = log_level_for_status(status)

    Logger.log(level, fn ->
      base_msg = "#{method} #{path} - #{status} in #{duration_ms}ms (#{remote_ip})"

      details =
        []
        |> maybe_add_user_agent(user_agent)
        |> maybe_add_request_id(request_id)
        |> Enum.join(", ")

      if details == "" do
        base_msg
      else
        "#{base_msg} [#{details}]"
      end
    end, metadata)
  end

  defp log_level_for_status(status) when status >= 500, do: :error
  defp log_level_for_status(status) when status >= 400, do: :warning
  defp log_level_for_status(_status), do: :info

  defp format_ip({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp format_ip({a, b, c, d, e, f, g, h}) do
    "#{Integer.to_string(a, 16)}:#{Integer.to_string(b, 16)}:#{Integer.to_string(c, 16)}:#{Integer.to_string(d, 16)}:#{Integer.to_string(e, 16)}:#{Integer.to_string(f, 16)}:#{Integer.to_string(g, 16)}:#{Integer.to_string(h, 16)}"
  end

  defp format_ip(_), do: "unknown"

  defp get_user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [user_agent | _] -> user_agent
      [] -> nil
    end
  end

  defp get_request_id(conn) do
    case get_req_header(conn, "x-request-id") do
      [request_id | _] -> request_id
      [] -> nil
    end
  end

  defp maybe_add_user_agent(list, nil), do: list
  defp maybe_add_user_agent(list, user_agent), do: ["ua=#{user_agent}" | list]

  defp maybe_add_request_id(list, nil), do: list
  defp maybe_add_request_id(list, request_id), do: ["req_id=#{request_id}" | list]
end
