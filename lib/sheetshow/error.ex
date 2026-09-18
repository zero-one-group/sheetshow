defmodule Sheetshow.Error do
  @moduledoc """
  The error behind every `{:error, _}` Sheetshow returns and every `!` variant
  raises.

  `reason` is an atom for your code to match on, `message` is for humans, and
  `details` carries whatever helps: the offending cell, the HTTP status, the
  ids that moved.

      iex> error = Sheetshow.Error.new(:invalid_style, "unknown style key :bolt", key: :bolt)
      iex> error.reason
      :invalid_style
      iex> error.details
      %{key: :bolt}
      iex> Exception.message(error)
      "unknown style key :bolt"

  ## The reasons

  Cells and ranges:

  | reason | meaning |
  | --- | --- |
  | `:invalid_a1` | a string that does not parse as A1 notation |
  | `:invalid_range` | a range a read cannot use: one that names no sheet |
  | `:invalid_cell`, `:invalid_value`, `:invalid_style` | a cell a plan refuses to write, with the cell in `details` |
  | `:missing_sheet` | a cell that names no sheet and was given none |

  Plans and sheets:

  | reason | meaning |
  | --- | --- |
  | `:unknown_sheet` | an op for a sheet the spreadsheet has not got |
  | `:duplicate_sheet` | an `AddSheet` for a sheet that is already there |
  | `:unsupported` | the backend cannot promise what was asked of it; see `Sheetshow.Backend` |

  Schemas, logs and tables:

  | reason | meaning |
  | --- | --- |
  | `:invalid_schema` | not a keyword list of known types |
  | `:invalid_record`, `:unknown_column` | a record a schema refuses to write: wrong type, or a key with no column |
  | `:cast` | a cell that would not read as its column's type; a flag on the row, or the error under `strict: true` |
  | `:missing_header`, `:missing_column` | a tab whose header is not there, or lacks a column the schema needs |
  | `:duplicate_column` | a tab whose header names a column the schema needs more than once, so there is no telling which to read |
  | `:missing_id` | an event with no id, which cannot be written |
  | `:unknown_id`, `:duplicate_id` | a change naming an id the snapshot cannot place, or one two rows share |
  | `:conflicting_changes` | two changes to one id in one plan |
  | `:moved` | the rows above a log cursor, or a table's header, have changed since the read: read again |

  Credentials and tokens:

  | reason | meaning |
  | --- | --- |
  | `:invalid_credentials` | a key file or `authorized_user` JSON that does not parse |
  | `:no_credentials`, `:no_token` | a workbook built without them, asked to do what needs them |
  | `:no_refresh_token` | a user account nobody has consented for yet |
  | `:auth` | the token endpoint or the consent screen refused |
  | `:state_mismatch` | an OAuth answer to a request that was not yours |
  | `:invalid_token_response` | a token endpoint answer with no token in it |

  The network and files:

  | reason | meaning |
  | --- | --- |
  | `:transport` | no answer at all: DNS, TCP, TLS or a timeout, in `details.reason` |
  | `:http` | any other non-2xx, with `details.status` and the server's message |
  | `:rate_limited` | Google's per-minute quota, with `details.retry_after` in seconds when it named one |
  | `:not_found` | a file or URL that is not there; `Sheetshow.Workbook.xlsx/2` with `create: true` makes one |
  | `:conflict` | a store refused a write because the file changed since it was read |
  | `:io` | the local filesystem refused, with the POSIX reason in `details.posix` |
  | `:invalid_zip`, `:invalid_xlsx`, `:unknown_entry` | a file that is not a workbook Sheetshow can read |
  """

  defexception [:reason, :message, details: %{}]

  @type reason ::
          :invalid_a1
          | :invalid_range
          | :invalid_cell
          | :invalid_value
          | :invalid_style
          | :missing_sheet
          | :unknown_sheet
          | :duplicate_sheet
          | :unsupported
          | :invalid_schema
          | :invalid_record
          | :unknown_column
          | :cast
          | :missing_header
          | :missing_column
          | :duplicate_column
          | :missing_id
          | :unknown_id
          | :duplicate_id
          | :conflicting_changes
          | :moved
          | :invalid_credentials
          | :no_credentials
          | :no_token
          | :no_refresh_token
          | :auth
          | :state_mismatch
          | :invalid_token_response
          | :transport
          | :http
          | :rate_limited
          | :not_found
          | :conflict
          | :io
          | :invalid_zip
          | :invalid_xlsx
          | :unknown_entry

  @type t :: %__MODULE__{reason: reason(), message: String.t(), details: map()}

  @doc """
  Builds an error. `details` may be a map or a keyword list.
  """
  @spec new(reason(), String.t(), map() | keyword()) :: t()
  def new(reason, message, details \\ %{}) when is_atom(reason) and is_binary(message) do
    %__MODULE__{reason: reason, message: message, details: Map.new(details)}
  end

  @doc false
  # What every `!` variant does: the value, or the error raised.
  @spec unwrap!({:ok, value} | {:error, Exception.t()}) :: value when value: term()
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, error}), do: raise(error)

  @doc false
  # The one error three backends build alike.
  @spec unknown_sheet(String.t(), [String.t()]) :: t()
  def unknown_sheet(title, titles) do
    new(:unknown_sheet, "there is no sheet #{inspect(title)}", sheet: title, sheets: titles)
  end
end
