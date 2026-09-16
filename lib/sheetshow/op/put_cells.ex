defmodule Sheetshow.Op.PutCells do
  @moduledoc """
  Writes a run of cells: one sheet, one row, consecutive columns, no gaps.

  The run is the unit because writing a rectangle replaces every cell in it,
  empty ones included. Scattered cells become several ops, one per run, so a
  write never clears a neighbour it did not mean to touch.

      iex> op = Sheetshow.Op.PutCells.new(Sheetshow.row(["Rent", 1000], sheet: "Costs"))
      iex> Sheetshow.Op.PutCells.range(op) |> Sheetshow.Range.to_a1()
      "Costs!A1:B1"

  A cell with no value and no style clears the cell it lands on.
  """

  alias Sheetshow.{Cell, Coord, Op, Range}

  @enforce_keys [:sheet]
  defstruct [:sheet, cells: []]

  @type t :: %__MODULE__{sheet: String.t(), cells: [Cell.t()]}

  @doc """
  Builds the op from cells, sorted left to right. The sheet comes from the
  cells unless given; `ArgumentError` if they disagree, sit on different rows
  or leave a gap.

      iex> Sheetshow.Op.PutCells.new(Sheetshow.row([1, 2]), "Costs").sheet
      "Costs"
      iex> cells = [Sheetshow.Cell.new("A1", 1), Sheetshow.Cell.new("C1", 3)]
      iex> Sheetshow.Op.PutCells.new(cells, "Costs")
      ** (ArgumentError) a PutCells run has no gaps: column 1 is missing between A1 and C1
  """
  @spec new([Cell.t()], String.t() | nil) :: t()
  def new(cells, sheet \\ nil)

  def new([_ | _] = cells, sheet) when is_binary(sheet) or is_nil(sheet) do
    sheet = sheet || Op.derive_sheet(cells, "a PutCells op")

    cells =
      cells
      |> Enum.sort_by(& &1.coord.col)
      |> Enum.map(&Cell.put_sheet(&1, nil))

    check_run!(cells)
    %__MODULE__{sheet: sheet, cells: cells}
  end

  def new([], _sheet), do: raise(ArgumentError, "a PutCells op needs at least one cell")

  defp check_run!([%Cell{coord: %Coord{row: row}} | _] = cells) do
    Enum.reduce(cells, nil, fn %Cell{coord: coord} = cell, previous ->
      cond do
        coord.row != row ->
          raise ArgumentError, "a PutCells run is one row, got #{a1(cell)} as well as row #{row}"

        previous != nil and coord.col == previous.coord.col ->
          raise ArgumentError, "a PutCells run writes each cell once, got #{a1(cell)} twice"

        previous != nil and coord.col != previous.coord.col + 1 ->
          raise ArgumentError,
                "a PutCells run has no gaps: column #{previous.coord.col + 1} is missing " <>
                  "between #{a1(previous)} and #{a1(cell)}"

        true ->
          cell
      end
    end)

    :ok
  end

  defp a1(%Cell{coord: coord}), do: Coord.to_a1(coord)

  @doc """
  The row the run sits on.

      iex> Sheetshow.Op.PutCells.new(Sheetshow.row([1], row: 3), "Costs") |> Sheetshow.Op.PutCells.row()
      3
  """
  @spec row(t()) :: non_neg_integer()
  def row(%__MODULE__{cells: [%Cell{coord: %Coord{row: row}} | _]}), do: row

  @doc """
  The column the run starts at.

      iex> Sheetshow.Op.PutCells.new(Sheetshow.row([1], col: 2), "Costs") |> Sheetshow.Op.PutCells.col()
      2
  """
  @spec col(t()) :: non_neg_integer()
  def col(%__MODULE__{cells: [%Cell{coord: %Coord{col: col}} | _]}), do: col

  @doc """
  The rectangle the op writes, which a backend turns into a grid range.

      iex> Sheetshow.Op.PutCells.new(Sheetshow.row([1, 2, 3]), "Costs")
      ...> |> Sheetshow.Op.PutCells.range()
      ...> |> Sheetshow.Range.to_a1()
      "Costs!A1:C1"
  """
  @spec range(t()) :: Range.t()
  def range(%__MODULE__{sheet: sheet, cells: cells} = op) do
    Range.new(sheet, row(op)..row(op), col(op)..(col(op) + length(cells) - 1))
  end
end
