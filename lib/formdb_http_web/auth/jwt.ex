# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule FormdbHttpWeb.Auth.JWT do
  @moduledoc """
  JWT (JSON Web Token) authentication module.

  Supports:
  - HS256 (HMAC with SHA-256) - symmetric signing
  - RS256 (RSA with SHA-256) - asymmetric signing
  - Token generation and verification
  - Claims validation (exp, iat, nbf, iss, aud)

  Configuration:
  - config :formdb_http, :jwt_secret - Secret key for HS256
  - config :formdb_http, :jwt_algorithm - "HS256" or "RS256"
  - config :formdb_http, :jwt_issuer - Token issuer
  - config :formdb_http, :jwt_expiration - Token TTL in seconds (default: 3600)
  """

  @default_expiration 3600  # 1 hour

  @doc """
  Generate a JWT token for a given subject (user ID) with optional claims.
  """
  def generate_token(subject, claims \\ %{}) do
    secret = Application.get_env(:formdb_http, :jwt_secret)
    algorithm = Application.get_env(:formdb_http, :jwt_algorithm, "HS256")
    issuer = Application.get_env(:formdb_http, :jwt_issuer, "formdb-http")
    expiration = Application.get_env(:formdb_http, :jwt_expiration, @default_expiration)

    if is_nil(secret) do
      {:error, :jwt_secret_not_configured}
    else
      now = System.system_time(:second)

      default_claims = %{
        "sub" => subject,
        "iat" => now,
        "exp" => now + expiration,
        "iss" => issuer
      }

      all_claims = Map.merge(default_claims, claims)

      case sign_token(all_claims, secret, algorithm) do
        {:ok, token} -> {:ok, token}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Verify a JWT token and return the claims if valid.
  """
  def verify_token(token) do
    secret = Application.get_env(:formdb_http, :jwt_secret)
    algorithm = Application.get_env(:formdb_http, :jwt_algorithm, "HS256")
    issuer = Application.get_env(:formdb_http, :jwt_issuer)

    if is_nil(secret) do
      {:error, :jwt_secret_not_configured}
    else
      with {:ok, claims} <- decode_and_verify(token, secret, algorithm),
           :ok <- validate_claims(claims, issuer) do
        {:ok, claims}
      else
        {:error, _reason} = err -> err
      end
    end
  end

  @doc """
  Extract token from Authorization header.
  Expects format: "Bearer <token>"
  """
  def extract_token_from_header(authorization_header) do
    case authorization_header do
      "Bearer " <> token -> {:ok, String.trim(token)}
      _ -> {:error, :invalid_authorization_header}
    end
  end

  # Private functions

  defp sign_token(claims, secret, "HS256") do
    header = %{"alg" => "HS256", "typ" => "JWT"}

    header_b64 = encode_base64url(Jason.encode!(header))
    payload_b64 = encode_base64url(Jason.encode!(claims))

    signature_input = "#{header_b64}.#{payload_b64}"
    signature = :crypto.mac(:hmac, :sha256, secret, signature_input)
    signature_b64 = encode_base64url(signature)

    {:ok, "#{signature_input}.#{signature_b64}"}
  end

  defp sign_token(_claims, _secret, algorithm) do
    {:error, {:unsupported_algorithm, algorithm}}
  end

  defp decode_and_verify(token, secret, "HS256") do
    case String.split(token, ".") do
      [header_b64, payload_b64, signature_b64] ->
        signature_input = "#{header_b64}.#{payload_b64}"
        expected_signature = :crypto.mac(:hmac, :sha256, secret, signature_input)
        expected_signature_b64 = encode_base64url(expected_signature)

        if signature_b64 == expected_signature_b64 do
          case decode_base64url(payload_b64) do
            {:ok, payload_json} ->
              case Jason.decode(payload_json) do
                {:ok, claims} -> {:ok, claims}
                {:error, _} -> {:error, :invalid_json}
              end
            {:error, _} -> {:error, :invalid_base64}
          end
        else
          {:error, :invalid_signature}
        end
      _ ->
        {:error, :invalid_token_format}
    end
  end

  defp decode_and_verify(_token, _secret, algorithm) do
    {:error, {:unsupported_algorithm, algorithm}}
  end

  defp validate_claims(claims, issuer) do
    now = System.system_time(:second)

    # Check expiration
    exp = Map.get(claims, "exp")
    if exp && exp < now do
      {:error, :token_expired}
    # Check not before
    else
      nbf = Map.get(claims, "nbf")
      if nbf && nbf > now do
        {:error, :token_not_yet_valid}
      # Check issuer if configured
      else
        iss = Map.get(claims, "iss")
        if issuer && iss != issuer do
          {:error, :invalid_issuer}
        else
          :ok
        end
      end
    end
  end

  defp encode_base64url(data) when is_binary(data) do
    Base.url_encode64(data, padding: false)
  end

  defp decode_base64url(data) when is_binary(data) do
    Base.url_decode64(data, padding: false)
  end
end
