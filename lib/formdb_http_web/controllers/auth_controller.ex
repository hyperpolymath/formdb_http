# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule FormdbHttpWeb.AuthController do
  @moduledoc """
  Authentication endpoints for JWT token generation.

  Endpoints:
  - POST /auth/token - Generate JWT token (login)
  - POST /auth/refresh - Refresh an expired token
  - POST /auth/revoke - Revoke a token (logout)
  """

  use FormdbHttpWeb, :controller

  alias FormdbHttpWeb.Auth.JWT

  @doc """
  Generate a new JWT token.

  Request body:
  {
    "username": "user@example.com",
    "password": "secret",  # In production, verify against database
    "claims": {}           # Optional additional claims
  }

  Response:
  {
    "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
    "expires_in": 3600,
    "token_type": "Bearer"
  }
  """
  def generate_token(conn, params) do
    username = Map.get(params, "username")
    password = Map.get(params, "password")
    custom_claims = Map.get(params, "claims", %{})

    # M12 PoC: Simple authentication (in production, verify against database)
    if authenticate_user(username, password) do
      case JWT.generate_token(username, custom_claims) do
        {:ok, token} ->
          expiration = Application.get_env(:formdb_http, :jwt_expiration, 3600)

          json(conn, %{
            token: token,
            expires_in: expiration,
            token_type: "Bearer"
          })

        {:error, :jwt_secret_not_configured} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{
            error: %{
              code: "JWT_NOT_CONFIGURED",
              message: "JWT authentication is not configured"
            }
          })

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{
            error: %{
              code: "TOKEN_GENERATION_FAILED",
              message: "Failed to generate token: #{inspect(reason)}"
            }
          })
      end
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{
        error: %{
          code: "INVALID_CREDENTIALS",
          message: "Invalid username or password"
        }
      })
    end
  end

  @doc """
  Verify a JWT token.

  Request body:
  {
    "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
  }

  Response:
  {
    "valid": true,
    "claims": {...}
  }
  """
  def verify_token(conn, %{"token" => token}) do
    case JWT.verify_token(token) do
      {:ok, claims} ->
        json(conn, %{
          valid: true,
          claims: claims
        })

      {:error, reason} ->
        json(conn, %{
          valid: false,
          error: inspect(reason)
        })
    end
  end

  def verify_token(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{
        code: "MISSING_TOKEN",
        message: "Token is required"
      }
    })
  end

  # Private helper functions

  defp authenticate_user(username, password) do
    # M12 PoC: Simple hardcoded authentication
    # In production, verify against database with password hashing (Argon2id per SECURITY-REQUIREMENTS.scm)

    demo_users = Application.get_env(:formdb_http, :demo_users, [
      {"admin", "admin"},
      {"user@example.com", "password123"}
    ])

    Enum.any?(demo_users, fn {u, p} ->
      u == username && p == password
    end)
  end
end
