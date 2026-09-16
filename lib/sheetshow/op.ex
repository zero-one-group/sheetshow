defmodule Sheetshow.Op do
  @moduledoc """
  What a backend is asked to do.

  A plan is a plain list of these, carried out in order. They say nothing about
  HTTP or about Google: `Sheetshow.Memory` interprets them in a map, and a
  backend encodes them as requests.

  | Op | What it does |
  |----|--------------|
  | `Sheetshow.Op.AddSheet` | adds a tab |
  | `Sheetshow.Op.DeleteSheet` | removes one |
  | `Sheetshow.Op.PutCells` | writes one run of cells along a row |
  | `Sheetshow.Op.AppendRows` | adds rows below the last row with data |
  | `Sheetshow.Op.DeleteRows` | removes rows, the ones below moving up |
  | `Sheetshow.Op.SetDimensions` | sets column widths or row heights |

  Every op names the sheet it works on, so the cells inside one are placed by
  row and column alone and their coordinates carry no sheet of their own. The
  constructors take cells that do and strip them.
  """

  alias Sheetshow.Op.{AddSheet, AppendRows, DeleteRows, DeleteSheet, PutCells, SetDimensions}

  @type t ::
          AddSheet.t()
          | AppendRows.t()
          | DeleteRows.t()
          | DeleteSheet.t()
          | PutCells.t()
          | SetDimensions.t()
  @type plan :: [t()]

  @modules [AddSheet, AppendRows, DeleteRows, DeleteSheet, PutCells, SetDimensions]

  @doc "Every op struct, for guards and tests."
  @spec modules() :: [module()]
  def modules, do: @modules

  @doc """
  The sheet an op works on.

      iex> Sheetshow.Op.sheet(Sheetshow.Op.AddSheet.new("Costs"))
      "Costs"
      iex> Sheetshow.Op.sheet(Sheetshow.Op.DeleteRows.new("log", 2..4))
      "log"
  """
  @spec sheet(t()) :: String.t()
  def sheet(%AddSheet{title: title}), do: title
  def sheet(%DeleteSheet{title: title}), do: title
  def sheet(%AppendRows{sheet: sheet}), do: sheet
  def sheet(%DeleteRows{sheet: sheet}), do: sheet
  def sheet(%PutCells{sheet: sheet}), do: sheet
  def sheet(%SetDimensions{sheet: sheet}), do: sheet

  @doc """
  Whether the term is one of the ops.

      iex> Sheetshow.Op.op?(Sheetshow.Op.AddSheet.new("Costs"))
      true
      iex> Sheetshow.Op.op?(:add_sheet)
      false
  """
  @spec op?(term()) :: boolean()
  def op?(%module{}), do: module in @modules
  def op?(_other), do: false

  @doc false
  # The sheet every cell in a group sits on, for constructors that derive it.
  @spec derive_sheet([Sheetshow.Cell.t()], String.t()) :: String.t()
  def derive_sheet(cells, what) do
    case cells |> Enum.map(& &1.coord.sheet) |> Enum.uniq() do
      [sheet] when is_binary(sheet) -> sheet
      [nil] -> raise ArgumentError, "#{what} needs a sheet: the cells name none"
      sheets -> raise ArgumentError, "#{what} needs one sheet, got #{inspect(sheets)}"
    end
  end
end
