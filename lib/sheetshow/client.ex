defmodule Sheetshow.Client do
  @moduledoc """
  How to reach one Google spreadsheet: which one, with which credentials.

  A client is a value you hold and pass in, not a process Sheetshow runs. It is
  the Google backend's half of a `Sheetshow.Workbook`: `Workbook.google/2`
  builds one for you, and `Sheetshow.connect/1` fills in the token.

      iex> client = Sheetshow.Client.new("1AbC")
      iex> client.spreadsheet_id
      "1AbC"
      iex> client.scopes
      ["https://www.googleapis.com/auth/spreadsheets"]

  Which sheets the spreadsheet has is the workbook's business, not the
  client's: see `Sheetshow.Workbook`.
  """

  alias Sheetshow.{Google, ServiceAccount, Token, UserAccount}

  @base_url "https://sheets.googleapis.com"

  @enforce_keys [:spreadsheet_id]
  defstruct [
    :spreadsheet_id,
    :credentials,
    :token,
    scopes: [],
    base_url: @base_url,
    http: []
  ]

  @type t :: %__MODULE__{
          spreadsheet_id: String.t(),
          credentials: ServiceAccount.t() | UserAccount.t() | nil,
          token: Token.t() | nil,
          scopes: [String.t()],
          base_url: String.t(),
          http: keyword()
        }

  @doc """
  Builds a client for one spreadsheet.

  Options: `:credentials` (a `Sheetshow.ServiceAccount` or a
  `Sheetshow.UserAccount`), `:token` (one you already hold), `:scopes`,
  `:base_url` and `:http`, which passes `:timeout`,
  `:connect_timeout` and `:ssl` through to the HTTP client.

      iex> Sheetshow.Client.new("1AbC", http: [timeout: 5_000]).http
      [timeout: 5_000]
  """
  @spec new(String.t(), keyword()) :: t()
  def new(spreadsheet_id, opts \\ []) when is_binary(spreadsheet_id) do
    %__MODULE__{
      spreadsheet_id: spreadsheet_id,
      credentials: Keyword.get(opts, :credentials),
      token: Keyword.get(opts, :token),
      scopes: Keyword.get(opts, :scopes, Google.default_scopes()),
      base_url: Keyword.get(opts, :base_url, @base_url),
      http: Keyword.get(opts, :http, [])
    }
  end

  @doc """
  Whether the client holds a token that is still good. Takes the moment to
  judge by, so a margin is yours to choose, as in `Sheetshow.Token.expired?/2`.

      iex> Sheetshow.Client.ready?(Sheetshow.Client.new("1AbC"))
      false
      iex> token = Sheetshow.Token.new("ya29.abc", ~U[2026-09-12 09:00:00Z])
      iex> Sheetshow.Client.ready?(Sheetshow.Client.new("1AbC", token: token), ~U[2026-09-12 08:00:00Z])
      true
  """
  @spec ready?(t(), DateTime.t()) :: boolean()
  def ready?(client, at \\ DateTime.utc_now())
  def ready?(%__MODULE__{token: nil}, _at), do: false
  def ready?(%__MODULE__{token: token}, at), do: not Token.expired?(token, at)

  @doc false
  @spec url(t(), String.t(), keyword()) :: String.t()
  def url(%__MODULE__{} = client, path, query \\ []) do
    url = "#{client.base_url}/v4/spreadsheets/#{URI.encode(client.spreadsheet_id)}#{path}"

    case query do
      [] -> url
      query -> url <> "?" <> URI.encode_query(query)
    end
  end
end
