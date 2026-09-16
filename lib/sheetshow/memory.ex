defmodule Sheetshow.Memory do
  @moduledoc """
  A spreadsheet in a map: the backend that needs no network.

  It carries out the same ops the Google backend does, so a plan can be run and
  read back in a test, and it refuses what Google refuses (writing to a sheet
  that is not there, adding one that is), so a plan that forgets its
  `Sheetshow.Op.AddSheet` fails here too.

      iex> alias Sheetshow.{Memory, Op}
      iex> plan = [
      ...>   Op.AddSheet.new("Costs"),
      ...>   Op.PutCells.new(Sheetshow.row(["Rent", 1000], sheet: "Costs"))
      ...> ]
      iex> {:ok, memory} = Memory.run(plan, Memory.new())
      iex> Memory.read!("Costs", memory) |> Sheetshow.to_rows()
      [["Rent", 1000]]

  A memory holds content, not a grid: it has no row or column count, so the
  space below the last cell is simply empty and a write can go anywhere. Each
  sheet is a plain map, `%{cells: %{{row, col} => cell}, col_widths: %{},
  row_heights: %{}}`, and the cells in it carry their sheet, so what `read/2`
  returns is what the layout functions in `Sheetshow` take.

  The functions here are the interpreter itself. `Sheetshow.Workbook.memory/1`
  puts a memory behind the same `Sheetshow.run/2` and reads the other backends
  answer to, which is the way to use one in a test.
  """

  alias Sheetshow.{Cell, Coord, Error, Op, Range, Result}

  defstruct sheets: %{}

  @type sheet :: %{
          cells: %{{non_neg_integer(), non_neg_integer()} => Cell.t()},
          col_widths: %{non_neg_integer() => pos_integer()},
          row_heights: %{non_neg_integer() => pos_integer()}
        }
  @type t :: %__MODULE__{sheets: %{String.t() => sheet()}}

  @empty %{cells: %{}, col_widths: %{}, row_heights: %{}}
  @ops [Op.AddSheet, Op.AppendRows, Op.DeleteRows, Op.DeleteSheet, Op.PutCells, Op.SetDimensions]

  @doc """
  An empty spreadsheet, or one with the sheets named already there.

      iex> Sheetshow.Memory.new(["Costs", "log"]) |> Sheetshow.Memory.titles()
      ["Costs", "log"]
  """
  @spec new([String.t()]) :: t()
  def new(titles \\ []) when is_list(titles) do
    %__MODULE__{sheets: Map.new(titles, &{&1, @empty})}
  end

  @doc """
  The sheet titles, sorted. A memory keeps no sheet order of its own.

      iex> Sheetshow.Memory.new() |> Sheetshow.Memory.titles()
      []
  """
  @spec titles(t()) :: [String.t()]
  def titles(%__MODULE__{sheets: sheets}), do: sheets |> Map.keys() |> Enum.sort()

  @doc """
  Carries out an op or a plan, in order, and gives back the spreadsheet it
  leaves behind. Mirrors `Sheetshow.run/2`, so a plan runs here or at Google
  with the same call shape.

  Nothing is half-done: the first op that fails ends the run and the memory you
  passed in is the one you still have.

      iex> alias Sheetshow.{Memory, Op}
      iex> {:error, error} = Memory.run(Op.PutCells.new(Sheetshow.row([1], sheet: "Costs")), Memory.new())
      iex> error.reason
      :unknown_sheet
  """
  @spec run(Op.t() | [Op.t()], t()) :: {:ok, t()} | {:error, Error.t()}
  def run(ops, memory)

  def run(%module{} = op, %__MODULE__{} = memory) when module in @ops, do: run([op], memory)

  def run(ops, %__MODULE__{} = memory) when is_list(ops), do: Result.reduce(ops, memory, &step/2)

  @doc "Same as `run/2`, raising on failure."
  @spec run!(Op.t() | [Op.t()], t()) :: t()
  def run!(ops, memory), do: ops |> run(memory) |> Error.unwrap!()

  @doc """
  The cells inside a range, in reading order. Empty cells are not cells, so
  they are not there.

      iex> alias Sheetshow.{Memory, Op}
      iex> memory = Memory.run!(Op.PutCells.new(Sheetshow.row([1, 2]), "Costs"), Memory.new(["Costs"]))
      iex> {:ok, cells} = Memory.read("Costs!A1:A1", memory)
      iex> Enum.map(cells, & &1.value)
      [1]
  """
  @spec read(Range.t() | String.t(), t()) :: {:ok, [Cell.t()]} | {:error, Error.t()}
  def read(range, memory)

  def read(a1, %__MODULE__{} = memory) when is_binary(a1) do
    with {:ok, range} <- Range.from_a1(a1), do: read(range, memory)
  end

  def read(%Range{} = range, %__MODULE__{} = memory) do
    with {:ok, %Range{sheet: title}} <- Range.on_sheet(range),
         {:ok, sheet} <- fetch(memory, title) do
      cells =
        sheet.cells
        |> Map.values()
        |> Enum.filter(&Range.contains?(range, &1.coord))
        |> Enum.sort_by(& &1.coord, Coord)

      {:ok, cells}
    end
  end

  @doc "Same as `read/2`, raising on failure."
  @spec read!(Range.t() | String.t(), t()) :: [Cell.t()]
  def read!(range, memory), do: range |> read(memory) |> Error.unwrap!()

  @doc """
  The column widths and row heights of a sheet, by index.

      iex> alias Sheetshow.{Memory, Op}
      iex> memory = Memory.run!(Op.SetDimensions.new("Costs", :cols, 0..1, 180), Memory.new(["Costs"]))
      iex> Sheetshow.Memory.dimensions!("Costs", memory)
      %{col_widths: %{0 => 180, 1 => 180}, row_heights: %{}}
  """
  @spec dimensions!(String.t(), t()) :: %{col_widths: map(), row_heights: map()}
  def dimensions!(title, %__MODULE__{} = memory) do
    sheet = memory |> fetch(title) |> Error.unwrap!()
    Map.take(sheet, [:col_widths, :row_heights])
  end

  @doc false
  # How a backend that reads a whole spreadsheet at once builds one: the cells
  # of a sheet, and the sizes of its columns and rows, put in place directly.
  # Every other way in goes through an op, because every other way in is a
  # change to a spreadsheet that already exists.
  @spec put_sheet(t(), String.t(), [Cell.t()], map(), map()) :: t()
  def put_sheet(%__MODULE__{} = memory, title, cells, col_widths \\ %{}, row_heights \\ %{})
      when is_binary(title) and is_list(cells) do
    held = %{
      cells: Map.new(cells, fn %Cell{coord: coord} = cell -> {{coord.row, coord.col}, cell} end),
      col_widths: col_widths,
      row_heights: row_heights
    }

    %{memory | sheets: Map.put(memory.sheets, title, held)}
  end

  defp step(%Op.AddSheet{title: title}, memory) do
    if Map.has_key?(memory.sheets, title) do
      {:error,
       Error.new(:duplicate_sheet, "the sheet #{inspect(title)} is already there", sheet: title)}
    else
      {:ok, %{memory | sheets: Map.put(memory.sheets, title, @empty)}}
    end
  end

  defp step(%Op.DeleteSheet{title: title}, memory) do
    with {:ok, _sheet} <- fetch(memory, title) do
      {:ok, %{memory | sheets: Map.delete(memory.sheets, title)}}
    end
  end

  defp step(%Op.PutCells{sheet: title, cells: cells}, memory) do
    update(memory, title, &put_cells(&1, title, cells))
  end

  defp step(%Op.AppendRows{sheet: title, cells: cells}, memory) do
    update(memory, title, fn sheet ->
      offset = next_row(sheet)
      put_cells(sheet, title, Enum.map(cells, &Cell.shift(&1, offset, 0)))
    end)
  end

  defp step(%Op.DeleteRows{sheet: title, rows: first.._last//1} = op, memory) do
    update(memory, title, &delete_rows(&1, first, Op.DeleteRows.count(op)))
  end

  defp step(%Op.SetDimensions{sheet: title} = op, memory) do
    key = if op.axis == :cols, do: :col_widths, else: :row_heights

    update(memory, title, fn sheet ->
      Map.update!(sheet, key, fn sizes ->
        Enum.reduce(op.indexes, sizes, &Map.put(&2, &1, op.pixels))
      end)
    end)
  end

  defp update(memory, title, fun) do
    with {:ok, sheet} <- fetch(memory, title) do
      {:ok, %{memory | sheets: Map.put(memory.sheets, title, fun.(sheet))}}
    end
  end

  defp fetch(memory, title) do
    case Map.fetch(memory.sheets, title) do
      {:ok, sheet} -> {:ok, sheet}
      :error -> {:error, Error.unknown_sheet(title, titles(memory))}
    end
  end

  # Writing a cell with nothing in it clears what was there, as an empty
  # CellData does at Google.
  defp put_cells(sheet, title, cells) do
    Enum.reduce(cells, sheet, fn %Cell{coord: coord} = cell, acc ->
      key = {coord.row, coord.col}

      cells =
        if blank?(cell) do
          Map.delete(acc.cells, key)
        else
          Map.put(acc.cells, key, Cell.put_sheet(cell, title))
        end

      %{acc | cells: cells}
    end)
  end

  defp blank?(%Cell{value: nil, style: style}), do: map_size(style) == 0
  defp blank?(%Cell{}), do: false

  defp next_row(sheet) do
    sheet.cells |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> -1 end) |> Kernel.+(1)
  end

  defp delete_rows(sheet, first, count) do
    cells =
      for {{row, col}, cell} <- sheet.cells, row < first or row >= first + count, into: %{} do
        moved = if row < first, do: 0, else: -count
        {{row + moved, col}, Cell.shift(cell, moved, 0)}
      end

    heights =
      for {row, pixels} <- sheet.row_heights, row < first or row >= first + count, into: %{} do
        {if(row < first, do: row, else: row - count), pixels}
      end

    %{sheet | cells: cells, row_heights: heights}
  end
end
