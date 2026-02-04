# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule FormdbHttpWeb.Plugs.Authenticate do
  @moduledoc """
  Authentication middleware for HTTP API.

  Supports multiple authentication methods:
  1. JWT Bearer tokens (Authorization: Bearer <token>)
  2. API keys (X-API-Key header)
  3. Optional: bypass for public endpoints

  Configuration:
  - auth_enabled: Enable/disable authentication (default: false for development)
  - public_paths: List of paths that don't require authentication

  Usage in router:
  ```
  pipeline :api_authenticated do
    plug :accepts, ["json"]
    plug FormdbHttpWeb.Plugs.Authenticate
  end
  ```
  """

  import Plug.Conn
  import Phoenix.Controller

  alias FormdbHttpWeb.Auth.JWT

  @behaviour Plug

  def init(opts) do
    opts
    |> Keyword.put_new(:auth_enabled, false)  # Disabled by default for M12 PoC
    |> Keyword.put_new(:public_paths, ["/health", "/health/live", "/health/ready", "/metrics"])
  end

  def call(conn, opts) do
    auth_enabled = Keyword.get(opts, :auth_enabled)
    public_paths = Keyword.get(opts, :public_paths)

    if auth_enabled && !is_public_path?(conn.request_path, public_paths) do
      authenticate(conn)
    else
      # Authentication disabled or public path - allow through
      conn
    end
  end

  defp authenticate(conn) do
    with {:ok, auth_header} <- get_authorization_header(conn),
         {:ok, token} <- JWT.extract_token_from_header(auth_header),
         {:ok, claims} <- JWT.verify_token(token) do
      # Authentication successful - store claims in conn
      conn
      |> assign(:authenticated, true)
      |> assign(:user_id, Map.get(claims, "sub"))
      |> assign(:claims, claims)
    else
      {:error, :no_authorization_header} ->
        # Check for API key as fallback
        case get_api_key(conn) do
          {:ok, api_key} -> verify_api_key(conn, api_key)
          {:error, :no_api_key} -> unauthorized(conn, "Missing authentication credentials")
        end

      {:error, :invalid_authorization_header} ->
        unauthorized(conn, "Invalid Authorization header format")

      {:error, :token_expired} ->
        unauthorized(conn, "Token expired")

      {:error, :invalid_signature} ->
        unauthorized(conn, "Invalid token signature")

      {:error, :jwt_secret_not_configured} ->
        internal_error(conn, "JWT not configured")

      {:error, reason} ->
        unauthorized(conn, "Authentication failed: #{inspect(reason)}")
    end
  end

  defp get_authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      [header | _] -> {:ok, header}
      [] -> {:error, :no_authorization_header}
    end
  end

  defp get_api_key(conn) do
    case get_req_header(conn, "x-api-key") do
      [api_key | _] -> {:ok, api_key}
      [] -> {:error, :no_api_key}
    end
  end

  defp verify_api_key(conn, api_key) do
    # Simple API key verification (in production, check against database)
    configured_keys = Application.get_env(:formdb_http, :api_keys, [])

    case Enum.find(configured_keys, fn key -> key == api_key end) do
      nil ->
        unauthorized(conn, "Invalid API key")
      _key ->
        conn
        |> assign(:authenticated, true)
        |> assign(:auth_method, :api_key)
        |> assign(:api_key, api_key)
    end
  end

  defp is_public_path?(path, public_paths) do
    Enum.any?(public_paths, fn public_path ->
      String.starts_with?(path, public_path)
    end)
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: FormdbHttpWeb.ErrorJSON)
    |> render(:"401", %{message: message})
    |> halt()
  end

  defp internal_error(conn, message) do
    conn
    |> put_status(:internal_server_error)
    |> put_view(json: FormdbHttpWeb.ErrorJSON)
    |> render(:"500", %{message: message})
    |> halt()
  end
end
