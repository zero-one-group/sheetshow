defmodule Sheetshow.Planner do
  @moduledoc false
  # Cells in, ops out. The docs for this live on `Sheetshow.plan/2`.

  alias Sheetshow.{Cell, Coord, Error, Result, Runs}
  alias Sheetshow.Op.{AddSheet, PutCells, SetDimensions}

  @options [:sheet, :existing_sheets]
  @dimensions [col_width: :cols, row_height: :rows]

  def plan(cells, opts) when is_list(cells) and is_list(opts) do
    opts = Keyword.validate!(opts, @options)

    with :ok <- validate(cells),
         {:ok, cells} <- on_sheets(cells, Keyword.get(opts, :sheet)) do
      titles = cells |> Enum.map(& &1.coord.sheet) |> Enum.uniq()
      order = titles |> Enum.with_index() |> Map.new()
      cells = last_wins(cells)

      {:ok,
       new_sheets(titles, Keyword.get(opts, :existing_sheets)) ++
         put_cells(cells, order) ++ set_dimensions(cells, order)}
    end
  end

  defp validate(cells) do
    Enum.find_value(cells, :ok, fn cell ->
      case Cell.validate(cell) do
        :ok -> nil
        {:error, _} = error -> error
      end
    end)
  end

  # Cells that name no sheet take the one given, and without one there is no
  # plan to make: an op has to say where it writes.
  defp on_sheets(cells, default) do
    Result.map(cells, fn cell ->
      case {cell.coord.sheet, default} do
        {nil, nil} -> {:error, missing_sheet(cell)}
        {nil, title} -> {:ok, Cell.put_sheet(cell, title)}
        {_sheet, _default} -> {:ok, cell}
      end
    end)
  end

  defp missing_sheet(%Cell{coord: coord} = cell) do
    Error.new(
      :missing_sheet,
      "the cell at #{Coord.to_a1(coord)} names no sheet: pass sheet: or use Sheetshow.put_sheet/2",
      cell: cell
    )
  end

  defp last_wins(cells) do
    cells
    |> Map.new(&{{&1.coord.sheet, &1.coord.row, &1.coord.col}, &1})
    |> Map.values()
  end

  defp new_sheets(_titles, nil), do: []

  defp new_sheets(titles, existing) when is_list(existing) do
    for title <- titles, title not in existing, do: AddSheet.new(title)
  end

  # One PutCells per run of neighbouring cells along a row, so a write never
  # clears a neighbour it did not mean to touch.
  defp put_cells(cells, order) do
    cells
    |> Enum.map(&formatted/1)
    |> Enum.group_by(&{&1.coord.sheet, &1.coord.row})
    |> Enum.sort_by(fn {{sheet, row}, _cells} -> {Map.fetch!(order, sheet), row} end)
    |> Enum.flat_map(fn {{sheet, _row}, row_cells} ->
      row_cells
      |> Enum.sort_by(& &1.coord.col)
      |> Runs.consecutive(& &1.coord.col)
      |> Enum.map(&PutCells.new(&1, sheet))
    end)
  end

  # Widths and heights belong to the grid, and a temporal value is a number
  # until a format says otherwise.
  defp formatted(%Cell{style: style} = cell) do
    Cell.with_number_format(%{cell | style: Map.drop(style, Keyword.keys(@dimensions))})
  end

  # The last cell in reading order sets a size, and neighbouring indexes of the
  # same size travel in one op.
  defp set_dimensions(cells, order) do
    sizes =
      for cell <- Enum.sort_by(cells, & &1.coord, Coord),
          {key, axis} <- @dimensions,
          pixels = Map.get(cell.style, key),
          into: %{} do
        index = if axis == :cols, do: cell.coord.col, else: cell.coord.row
        {{cell.coord.sheet, axis, index}, pixels}
      end

    sizes
    |> Enum.group_by(
      fn {{sheet, axis, _index}, _pixels} -> {sheet, axis} end,
      fn {{_sheet, _axis, index}, pixels} -> {index, pixels} end
    )
    |> Enum.sort_by(fn {{sheet, axis}, _sizes} -> {Map.fetch!(order, sheet), axis} end)
    |> Enum.flat_map(fn {{sheet, axis}, sizes} ->
      sizes
      |> Enum.sort()
      |> Runs.consecutive(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn [{first, pixels} | _] = run ->
        SetDimensions.new(sheet, axis, first..elem(List.last(run), 0), pixels)
      end)
    end)
  end
end
