defmodule Sheetshow.UserAccount do
  @moduledoc """
  A person's own Google account, as a value: the app you registered, and the
  refresh token they gave it.

  The sibling of `Sheetshow.ServiceAccount`, and a client takes either. A
  service account is a robot with a private key and its own email address, which
  a spreadsheet has to be shared with; a user account acts as the person who
  signed in, and sees the spreadsheets they see. Both are credentials
  `Sheetshow.connect/1` turns into a `Sheetshow.Token`, and nothing downstream
  of that knows the difference.

      iex> account = Sheetshow.UserAccount.new("123.apps.googleusercontent.com", "secret")
      iex> Sheetshow.UserAccount.authorized?(account)
      false

  It has two stages, which is why `refresh_token` may be `nil`. A new account is
  the app's own credentials and nothing else, which is enough to send somebody
  to a consent screen, which is `Sheetshow.OAuth`'s half of the job. What comes back
  from `Sheetshow.OAuth.authorize/3` is the same account with a refresh token on
  it, and that is the thing worth keeping.

  That pair of stages is not an invention: it is exactly the shape of the
  `authorized_user` JSON that `gcloud` writes, so `from_file/1` reads a file
  `gcloud auth application-default login` made, and `to_json/1` writes one
  anything else that reads the format will take.

  Inspecting an account shows neither the secret nor the refresh token.
  """

  alias Sheetshow.{Credentials, Error}

  @derive {Inspect, except: [:client_secret, :refresh_token]}
  @enforce_keys [:client_id, :client_secret, :token_uri]
  defstruct [:client_id, :client_secret, :token_uri, :refresh_token]

  @type t :: %__MODULE__{
          client_id: String.t(),
          client_secret: String.t(),
          token_uri: String.t(),
          refresh_token: String.t() | nil
        }

  @token_uri "https://oauth2.googleapis.com/token"
  @grant_type "refresh_token"

  @doc """
  An account from the client id and secret of an app you registered in the
  Google Cloud console.

  Options: `:refresh_token`, when you already hold one, and `:token_uri`.

      iex> account = Sheetshow.UserAccount.new("123.apps.googleusercontent.com", "s", refresh_token: "1//r")
      iex> Sheetshow.UserAccount.authorized?(account)
      true
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(client_id, client_secret, opts \\ [])
      when is_binary(client_id) and is_binary(client_secret) do
    %__MODULE__{
      client_id: client_id,
      client_secret: client_secret,
      token_uri: Keyword.get(opts, :token_uri, @token_uri),
      refresh_token: Keyword.get(opts, :refresh_token)
    }
  end

  @doc """
  Whether this account can get a token on its own, that is, whether somebody
  has been through the consent screen for it.

      iex> Sheetshow.UserAccount.new("123", "s") |> Sheetshow.UserAccount.authorized?()
      false
  """
  @spec authorized?(t()) :: boolean()
  def authorized?(%__MODULE__{refresh_token: refresh_token}), do: is_binary(refresh_token)

  @doc """
  Reads the JSON of an `authorized_user` credential.

      iex> json = ~s({"type":"authorized_user","client_id":"123","client_secret":"s","refresh_token":"1//r"})
      iex> {:ok, account} = Sheetshow.UserAccount.from_json(json)
      iex> account.client_id
      "123"

      iex> {:error, %Sheetshow.Error{reason: :invalid_credentials}} =
      ...>   Sheetshow.UserAccount.from_json(~s({"type": "service_account"}))
  """
  @spec from_json(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_json(json) when is_binary(json) do
    with {:ok, map} <- Credentials.decode(json, "an authorized_user credential"),
         do: from_map(map)
  end

  @doc "Same as `from_json/1`, raising on failure."
  @spec from_json!(String.t()) :: t()
  def from_json!(json), do: json |> from_json() |> Error.unwrap!()

  @doc """
  Reads an `authorized_user` credential file. The path is yours to supply, and
  nothing about it is remembered.
  """
  @spec from_file(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_file(path), do: Credentials.from_file(path, &from_json/1)

  @doc "Same as `from_file/1`, raising on failure."
  @spec from_file!(Path.t()) :: t()
  def from_file!(path), do: path |> from_file() |> Error.unwrap!()

  @doc """
  The account as `authorized_user` JSON, to write somewhere only you can read.
  Where that is, and how it is protected, is your application's business.

      iex> Sheetshow.UserAccount.new("123", "s", refresh_token: "1//r")
      ...> |> Sheetshow.UserAccount.to_json()
      ...> |> JSON.decode!()
      ...> |> Map.get("type")
      "authorized_user"
  """
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = account) do
    JSON.encode!(%{
      "type" => "authorized_user",
      "client_id" => account.client_id,
      "client_secret" => account.client_secret,
      "refresh_token" => account.refresh_token
    })
  end

  @doc """
  The token request as data, where to post and what to post, for whichever
  HTTP client is doing the talking. An account with no refresh token has nothing
  to ask with, and says so.

      Sheetshow.UserAccount.token_request(account)
      {:ok, %{
        url: "https://oauth2.googleapis.com/token",
        form: %{grant_type: "refresh_token", refresh_token: "1//r", client_id: "123", client_secret: "s"}
      }}
  """
  @spec token_request(t()) :: {:ok, %{url: String.t(), form: map()}} | {:error, Error.t()}
  def token_request(%__MODULE__{refresh_token: nil}) do
    {:error,
     Error.new(
       :no_refresh_token,
       "this account has not been through a consent screen: Sheetshow.OAuth.consent_url/2 " <>
         "sends somebody to one and Sheetshow.OAuth.authorize/3 finishes the job"
     )}
  end

  def token_request(%__MODULE__{} = account) do
    {:ok,
     %{
       url: account.token_uri,
       form: %{
         grant_type: @grant_type,
         refresh_token: account.refresh_token,
         client_id: account.client_id,
         client_secret: account.client_secret
       }
     }}
  end

  @doc false
  @spec default_token_uri() :: String.t()
  def default_token_uri, do: @token_uri

  defp from_map(%{"type" => "authorized_user"} = map) do
    with {:ok, client_id} <- Credentials.fetch(map, "client_id"),
         {:ok, client_secret} <- Credentials.fetch(map, "client_secret") do
      {:ok,
       %__MODULE__{
         client_id: client_id,
         client_secret: client_secret,
         token_uri: Map.get(map, "token_uri", @token_uri),
         refresh_token: refresh_token(map)
       }}
    end
  end

  defp from_map(%{"type" => type}) do
    {:error, invalid("expected an authorized_user credential, got #{inspect(type)}", type: type)}
  end

  defp from_map(_map), do: {:error, invalid(~s(a credential needs a "type"))}

  defp refresh_token(map) do
    case Map.get(map, "refresh_token") do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  defp invalid(message, details \\ []), do: Credentials.invalid(message, details)
end
