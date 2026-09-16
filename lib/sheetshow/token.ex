defmodule Sheetshow.Token do
  @moduledoc """
  An access token and the moment it stops working.

  A token is a value. Sheetshow hands you one and takes no further interest:
  where you keep it, when you refresh it and whether you share it between
  processes are your decisions, not the library's.

      iex> token = Sheetshow.Token.new("ya29.abc", ~U[2026-09-12 09:00:00Z])
      iex> Sheetshow.Token.expired?(token, ~U[2026-09-12 08:59:00Z])
      false
      iex> Sheetshow.Token.authorization(token)
      "Bearer ya29.abc"

  Inspecting a token shows everything but the token itself, so one can be
  printed in a log or a test failure without leaking.
  """

  alias Sheetshow.Error

  @derive {Inspect, except: [:access_token]}
  @enforce_keys [:access_token, :expires_at]
  defstruct [:access_token, :expires_at, type: "Bearer", scopes: []]

  @type t :: %__MODULE__{
          access_token: String.t(),
          expires_at: DateTime.t(),
          type: String.t(),
          scopes: [String.t()]
        }

  @doc """
  Builds a token. Options: `:type` (default `"Bearer"`) and `:scopes`.

      iex> Sheetshow.Token.new("ya29.abc", ~U[2026-09-12 09:00:00Z], scopes: ["a"]).scopes
      ["a"]
  """
  @spec new(String.t(), DateTime.t(), keyword()) :: t()
  def new(access_token, %DateTime{} = expires_at, opts \\ []) when is_binary(access_token) do
    %__MODULE__{
      access_token: access_token,
      expires_at: expires_at,
      type: Keyword.get(opts, :type, "Bearer"),
      scopes: Keyword.get(opts, :scopes, [])
    }
  end

  @doc """
  A token from what the token endpoint answered, with `expires_in` turned into
  a moment. Options: `:now` (default now) and `:scopes`, used when the answer
  does not name them.

      iex> {:ok, token} =
      ...>   Sheetshow.Token.from_response(%{"access_token" => "ya29.abc", "expires_in" => 3600},
      ...>     now: ~U[2026-09-12 08:00:00Z]
      ...>   )
      iex> token.expires_at
      ~U[2026-09-12 09:00:00Z]

      iex> {:error, %Sheetshow.Error{reason: :auth}} =
      ...>   Sheetshow.Token.from_response(%{"error" => "invalid_grant"})
  """
  @spec from_response(map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_response(response, opts \\ []) when is_map(response) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case response do
      %{"error" => error} ->
        {:error,
         Error.new(:auth, "the token endpoint refused: #{describe(response, error)}",
           error: error,
           response: response
         )}

      %{"access_token" => access_token, "expires_in" => expires_in}
      when is_binary(access_token) ->
        with {:ok, seconds} <- seconds(expires_in) do
          {:ok,
           %__MODULE__{
             access_token: access_token,
             expires_at: now |> DateTime.add(seconds, :second) |> DateTime.truncate(:second),
             type: Map.get(response, "token_type", "Bearer"),
             scopes: scopes(response, opts)
           }}
        end

      _other ->
        {:error,
         Error.new(
           :invalid_token_response,
           "expected access_token and expires_in, got keys #{inspect(Map.keys(response))}",
           response: response
         )}
    end
  end

  @doc "Same as `from_response/2`, raising on failure."
  @spec from_response!(map(), keyword()) :: t()
  def from_response!(response, opts \\ []), do: response |> from_response(opts) |> Error.unwrap!()

  @doc """
  Whether the token has run out. Pass a moment in the future for a margin:
  `expired?(token, DateTime.add(DateTime.utc_now(), 60))` asks whether it will
  still be good in a minute.

      iex> token = Sheetshow.Token.new("ya29.abc", ~U[2026-09-12 09:00:00Z])
      iex> Sheetshow.Token.expired?(token, ~U[2026-09-12 09:00:00Z])
      true
  """
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}, at \\ DateTime.utc_now()) do
    DateTime.compare(at, expires_at) != :lt
  end

  @doc """
  The `Authorization` header's value.

      iex> Sheetshow.Token.new("ya29.abc", ~U[2026-09-12 09:00:00Z]) |> Sheetshow.Token.authorization()
      "Bearer ya29.abc"
  """
  @spec authorization(t()) :: String.t()
  def authorization(%__MODULE__{type: type, access_token: access_token}) do
    type <> " " <> access_token
  end

  defp seconds(expires_in) when is_integer(expires_in), do: {:ok, expires_in}

  defp seconds(expires_in) when is_binary(expires_in) do
    case Integer.parse(expires_in) do
      {seconds, ""} -> {:ok, seconds}
      _ -> {:error, invalid_expires_in(expires_in)}
    end
  end

  defp seconds(expires_in), do: {:error, invalid_expires_in(expires_in)}

  defp invalid_expires_in(expires_in) do
    Error.new(
      :invalid_token_response,
      "expires_in should be a number of seconds, got #{inspect(expires_in)}",
      expires_in: expires_in
    )
  end

  defp scopes(response, opts) do
    case Map.get(response, "scope") do
      scope when is_binary(scope) -> String.split(scope, " ", trim: true)
      _ -> Keyword.get(opts, :scopes, [])
    end
  end

  defp describe(response, error) do
    case Map.get(response, "error_description") do
      nil -> to_string(error)
      description -> "#{error} (#{description})"
    end
  end
end
