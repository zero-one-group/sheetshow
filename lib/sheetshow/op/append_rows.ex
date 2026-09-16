defmodule Sheetshow.Op.AppendRows do
  @moduledoc """
  Adds rows below the last row with data on the sheet.

  The cells are placed relative to the append point: row 0 is the first new
  row, row 1 the one after it, and columns are absolute. Rows may be sparse,
  and a leading gap leaves blank rows.

      iex> rows = [["a", 1], ["b", 2]]
      iex> op = Sheetshow.Op.AppendRows.new(Sheetshow.rows(rows), "log")
      iex> Sheetshow.Op.AppendRows.height(op)
      2

  Nothing here needs to know where the data ends, which is why appending is
  safe to retry against a sheet someone else is also writing to.
  """

  alias Sheetshow.{Cell, Op}

  @enforce_keys [:sheet]
  defstruct [:sheet, cells: []]

  @type t :: %__MODULE__{sheet: String.t(), cells: [Cell.t()]}

  @doc """
  Builds the op from cells. The sheet comes from the cells unless given.

      iex> Sheetshow.Op.AppendRows.new(Sheetshow.row([1], sheet: "log")).sheet
      "log"
  """
  @spec new([Cell.t()], String.t() | nil) :: t()
  def new(cells, sheet \\ nil)

  def new([_ | _] = cells, sheet) when is_binary(sheet) or is_nil(sheet) do
    %__MODULE__{
      sheet: sheet || Op.derive_sheet(cells, "an AppendRows op"),
      cells: Enum.map(cells, &Cell.put_sheet(&1, nil))
    }
  end

  def new([], sheet) when is_binary(sheet), do: %__MODULE__{sheet: sheet, cells: []}

  @doc """
  How many rows the op adds.

      iex> Sheetshow.Op.AppendRows.new([], "log") |> Sheetshow.Op.AppendRows.height()
      0
  """
  @spec height(t()) :: non_neg_integer()
  def height(%__MODULE__{cells: cells}) do
    case Sheetshow.max_row(cells) do
      nil -> 0
      row -> row + 1
    end
  end
end
