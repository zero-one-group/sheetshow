defmodule Sheetshow.ServiceAccount do
  @moduledoc """
  A Google service account, as a value: what the key file holds, and the signed
  assertion that trades it for a `Sheetshow.Token`.

  Google's flow is two steps. You sign a short-lived claim, *I am this service
  account and I would like these scopes*, with the account's private key, and
  the token endpoint gives back an access token. `assertion/2` does the first
  step; the second is one HTTP request, and `token_request/2` is the data for
  it, so everything here stays pure.

      iex> pem = :public_key.pem_encode([
      ...>   :public_key.pem_entry_encode(:RSAPrivateKey, :public_key.generate_key({:rsa, 2048, 65537}))
      ...> ])
      iex> json = JSON.encode!(%{
      ...>   "type" => "service_account",
      ...>   "client_email" => "tests@example.iam.gserviceaccount.com",
      ...>   "private_key" => pem
      ...> })
      iex> account = Sheetshow.ServiceAccount.from_json!(json)
      iex> account |> Sheetshow.ServiceAccount.assertion() |> String.split(".") |> length()
      3

  Sheetshow never looks for a credential of its own accord: there is no
  well-known path, no environment variable, no cache. You read the file, you
  hold the token. Inspecting an account shows everything but the key.
  """

  alias Sheetshow.{Credentials, Error, Google}

  @derive {Inspect, except: [:private_key]}
  @enforce_keys [:client_email, :private_key, :token_uri]
  defstruct [:client_email, :private_key, :token_uri, :project_id, :private_key_id]

  @type t :: %__MODULE__{
          client_email: String.t(),
          private_key: String.t(),
          token_uri: String.t(),
          project_id: String.t() | nil,
          private_key_id: String.t() | nil
        }

  @token_uri "https://oauth2.googleapis.com/token"
  @grant_type "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @lifetime 3600

  @doc """
  Reads the JSON of a service-account key file. The private key is decoded
  here, so a credential that parses is one that can sign.

      iex> {:error, %Sheetshow.Error{reason: :invalid_credentials}} =
      ...>   Sheetshow.ServiceAccount.from_json(~s({"type": "authorized_user"}))
  """
  @spec from_json(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_json(json) when is_binary(json) do
    with {:ok, map} <- Credentials.decode(json, "a service-account key file"), do: from_map(map)
  end

  @doc "Same as `from_json/1`, raising on failure."
  @spec from_json!(String.t()) :: t()
  def from_json!(json), do: json |> from_json() |> Error.unwrap!()

  @doc """
  Reads a service-account key file. A convenience over `from_json/1`: the path
  is yours to supply, and nothing about it is remembered.
  """
  @spec from_file(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_file(path), do: Credentials.from_file(path, &from_json/1)

  @doc "Same as `from_file/1`, raising on failure."
  @spec from_file!(Path.t()) :: t()
  def from_file!(path), do: path |> from_file() |> Error.unwrap!()

  @doc """
  The signed JWT that asks for an access token.

  Options: `:scopes` (default `Sheetshow.Google.default_scopes/0`), `:lifetime` in seconds
  (default one hour, Google's maximum) and `:now`, which is there so a test can
  say when it is.

      account |> Sheetshow.ServiceAccount.assertion(scopes: ["https://www.googleapis.com/auth/spreadsheets.readonly"])
      "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJodHRwczovL29hdXRoMi5nb..."
  """
  @spec assertion(t(), keyword()) :: String.t()
  def assertion(%__MODULE__{} = account, opts \\ []) do
    issued_at = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.to_unix()
    lifetime = Keyword.get(opts, :lifetime, @lifetime)

    claims = %{
      iss: account.client_email,
      scope: opts |> Keyword.get(:scopes, Google.default_scopes()) |> Enum.join(" "),
      aud: account.token_uri,
      iat: issued_at,
      exp: issued_at + lifetime
    }

    payload = segment(%{alg: "RS256", typ: "JWT"}) <> "." <> segment(claims)
    payload <> "." <> base64(sign(payload, account.private_key))
  end

  @doc """
  The token request as data, where to post and what to post, for whichever
  HTTP client is doing the talking. Takes the same options as `assertion/2`.

      Sheetshow.ServiceAccount.token_request(account)
      %{
        url: "https://oauth2.googleapis.com/token",
        form: %{grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: "eyJhbGci..."}
      }
  """
  @spec token_request(t(), keyword()) :: %{url: String.t(), form: map()}
  def token_request(%__MODULE__{} = account, opts \\ []) do
    %{
      url: account.token_uri,
      form: %{grant_type: @grant_type, assertion: assertion(account, opts)}
    }
  end

  defp from_map(%{"type" => "service_account"} = map) do
    with {:ok, client_email} <- Credentials.fetch(map, "client_email"),
         {:ok, private_key} <- Credentials.fetch(map, "private_key"),
         :ok <- check_key(private_key) do
      {:ok,
       %__MODULE__{
         client_email: client_email,
         private_key: private_key,
         token_uri: Map.get(map, "token_uri", @token_uri),
         project_id: map["project_id"],
         private_key_id: map["private_key_id"]
       }}
    end
  end

  defp from_map(%{"type" => type}) do
    {:error, invalid("expected a service_account credential, got #{inspect(type)}", type: type)}
  end

  defp from_map(_map), do: {:error, invalid(~s(a credential needs a "type"))}

  defp check_key(private_key) do
    case decode_key(private_key) do
      {:ok, _key} -> :ok
      :error -> {:error, invalid("the credential's private_key is not a PEM-encoded RSA key")}
    end
  end

  defp decode_key(private_key) do
    case :public_key.pem_decode(private_key) do
      [entry] -> {:ok, :public_key.pem_entry_decode(entry)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp sign(payload, private_key) do
    {:ok, key} = decode_key(private_key)
    :public_key.sign(payload, :sha256, key)
  end

  defp segment(map), do: map |> JSON.encode!() |> base64()

  defp base64(binary), do: Base.url_encode64(binary, padding: false)

  defp invalid(message, details \\ []), do: Credentials.invalid(message, details)
end
