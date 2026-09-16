defmodule Sheetshow.Memory.Backend do
  @moduledoc false
  # `Sheetshow.Memory` behind the same seam as Google, so a workbook can be run
  # and read back with no network at all. The docs live on the `Sheetshow`
  # functions that call these, and on `Sheetshow.Memory` itself.

  @behaviour Sheetshow.Backend

  alias Sheetshow.{Cell, Memory, Range, Result, Workbook}

  # A memory applies a plan whole or not at all, keeps styles and dimensions,
  # and resolves an append against the memory it is applied to, at that moment,
  # which is the property `Sheetshow.Log` rests on, and it holds here because a
  # memory is one value with one owner. It evaluates no formulas, so a formula
  # written here reads back as the formula it is, and `Sheetshow.Log.view/2`
  # cannot be checked against it. Nothing conditional: there is no version to
  # compare against.
  @impl true
  def capabilities(_workbook) do
    %{
      atomic_batch: true,
      conditional_write: false,
      dimensions: true,
      evaluates_formulas: false,
      server_side_append: true,
      styles: true
    }
  end

  # Nothing to reach and no credentials to trade: a memory is ready as it is.
  @impl true
  def connect(%Workbook{} = workbook), do: fetch_sheets(workbook)

  @impl true
  def fetch_sheets(%Workbook{ref: %Memory{} = memory} = workbook) do
    {:ok, Workbook.put_sheets(workbook, Map.new(Memory.titles(memory), &{&1, nil}))}
  end

  @impl true
  def run(plan, %Workbook{ref: %Memory{} = memory} = workbook) when is_list(plan) do
    with {:ok, memory} <- Memory.run(plan, memory) do
      workbook |> Workbook.put_ref(memory) |> fetch_sheets()
    end
  end

  @impl true
  def read_cells(%Range{} = range, %Workbook{ref: %Memory{} = memory}) do
    Memory.read(range, memory)
  end

  @impl true
  def read_rows(%Range{} = range, %Workbook{ref: %Memory{} = memory}) do
    with {:ok, cells} <- Memory.read(range, memory), do: {:ok, rows(cells, range)}
  end

  @impl true
  def read_rows_batch(ranges, %Workbook{} = workbook) when is_list(ranges) do
    Result.map(ranges, &read_rows(&1, workbook))
  end

  # What the values endpoint gives back, after `Sheetshow.Google.decode_values/1`
  # has padded it: rows from the range's own first row down to the last row
  # holding anything, each as wide as the widest, with an empty cell as nil.
  # Rows below the last one with something in it are not there, which is what
  # Google does too.
  defp rows([], _range), do: []

  defp rows(cells, %Range{start_row: first_row, start_col: first_col}) do
    values =
      Map.new(cells, fn %Cell{coord: coord, value: value} -> {{coord.row, coord.col}, value} end)

    last_row = cells |> Enum.map(& &1.coord.row) |> Enum.max()
    last_col = cells |> Enum.map(& &1.coord.col) |> Enum.max()

    for row <- first_row..last_row//1 do
      for col <- first_col..last_col//1, do: Map.get(values, {row, col})
    end
  end
end
