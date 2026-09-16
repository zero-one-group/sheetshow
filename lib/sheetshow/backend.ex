defmodule Sheetshow.Backend do
  @moduledoc """
  What a backend has to do, and what it can promise.

  Every impure function in `Sheetshow` takes a `Sheetshow.Workbook` and asks
  the module named on it to do the work. Three come with the library (Google,
  the in-memory one and xlsx), and they are not equals: one evaluates formulas
  and resolves an append server-side, another does neither. `capabilities/1` is
  how that difference is said out loud rather than discovered. Reach for a
  backend through `Sheetshow.Workbook.google/2`, `Sheetshow.Workbook.memory/1` or
  `Sheetshow.Workbook.xlsx/2`; the
  modules behind them are the library's own business.

      iex> Sheetshow.Workbook.memory() |> Sheetshow.Backend.supports?(:evaluates_formulas)
      false

  The capabilities:

  | capability | what it promises |
  | --- | --- |
  | `:atomic_batch` | a plan is applied whole or not at all |
  | `:conditional_write` | a write can be refused if the spreadsheet has changed since you read it |
  | `:dimensions` | column widths and row heights are kept |
  | `:evaluates_formulas` | a formula written here is worked out, so it can be read back as a value |
  | `:server_side_append` | an append resolves against the last row at the moment it is applied, so two writers cannot land on each other |
  | `:styles` | a cell's style is kept |

  `:server_side_append` is the one `Sheetshow.Log` rests on, and
  `:conditional_write` is what gives `Sheetshow.Table` the guarantee Google
  cannot; [What Sheetshow Can Promise](guides/guarantees.md) says how.
  """

  alias Sheetshow.{Cell, Error, Op, Range, Workbook}

  @type capability ::
          :atomic_batch
          | :conditional_write
          | :dimensions
          | :evaluates_formulas
          | :server_side_append
          | :styles

  @type capabilities :: %{capability() => boolean()}

  @known [
    :atomic_batch,
    :conditional_write,
    :dimensions,
    :evaluates_formulas,
    :server_side_append,
    :styles
  ]

  @doc """
  What this backend promises for this workbook. Every capability in `known/0`
  has an answer.

  Per workbook rather than per backend, because a backend's promises can depend
  on where it is pointed: the same xlsx codec over a local file cannot refuse a
  write that would clobber someone, and over a store that speaks `If-Match` it
  can.
  """
  @callback capabilities(Workbook.t()) :: capabilities()

  @doc "Makes the workbook ready to use, and learns its sheets."
  @callback connect(Workbook.t()) :: {:ok, Workbook.t()} | {:error, Error.t()}

  @doc "Asks the spreadsheet which sheets it has."
  @callback fetch_sheets(Workbook.t()) :: {:ok, Workbook.t()} | {:error, Error.t()}

  @doc "Carries out a plan."
  @callback run(Op.plan(), Workbook.t()) :: {:ok, Workbook.t()} | {:error, Error.t()}

  @doc "The cells in a range. Every range a backend is given names its sheet."
  @callback read_cells(Range.t(), Workbook.t()) :: {:ok, [Cell.t()]} | {:error, Error.t()}

  @doc "The values in a range, as rows."
  @callback read_rows(Range.t(), Workbook.t()) :: {:ok, [[term()]]} | {:error, Error.t()}

  @doc "The values in several ranges, in the order they were asked for."
  @callback read_rows_batch([Range.t()], Workbook.t()) ::
              {:ok, [[[term()]]]} | {:error, Error.t()}

  @doc "Trades credentials for a token. Only a backend that has credentials has this."
  @callback authenticate(Workbook.t()) :: {:ok, Workbook.t()} | {:error, Error.t()}

  @optional_callbacks authenticate: 1

  @doc """
  Every capability a backend answers for.

      iex> Sheetshow.Backend.known() |> Enum.member?(:server_side_append)
      true
  """
  @spec known() :: [capability()]
  def known, do: @known

  @doc """
  What the workbook's backend promises.

      iex> Sheetshow.Workbook.memory() |> Sheetshow.Backend.capabilities() |> Map.fetch!(:atomic_batch)
      true
  """
  @spec capabilities(Workbook.t()) :: capabilities()
  def capabilities(%Workbook{backend: backend} = workbook), do: backend.capabilities(workbook)

  @doc """
  Whether the workbook's backend promises one thing.

      iex> Sheetshow.Workbook.memory() |> Sheetshow.Backend.supports?(:server_side_append)
      true
  """
  @spec supports?(Workbook.t(), capability()) :: boolean()
  def supports?(%Workbook{} = workbook, capability) when capability in @known do
    Map.fetch!(capabilities(workbook), capability)
  end

  @doc """
  `:ok` when the backend promises the capability, and an error naming it when
  it does not. What a caller uses to refuse before writing rather than after.

      iex> {:error, error} = Sheetshow.Workbook.memory() |> Sheetshow.Backend.ensure(:evaluates_formulas)
      iex> error.reason
      :unsupported
  """
  @spec ensure(Workbook.t(), capability()) :: :ok | {:error, Error.t()}
  def ensure(%Workbook{backend: backend} = workbook, capability) when capability in @known do
    if supports?(workbook, capability) do
      :ok
    else
      {:error,
       Error.new(
         :unsupported,
         "#{inspect(backend)} does not support #{inspect(capability)}",
         backend: backend,
         capability: capability
       )}
    end
  end
end
