defmodule Sheetshow.PlannerTest do
  use ExUnit.Case, async: true

  alias Sheetshow.{Cell, Error, Memory}
  alias Sheetshow.Op.{AddSheet, PutCells, SetDimensions}

  defp a1(plan) do
    for %PutCells{} = op <- plan, do: Sheetshow.Range.to_a1(PutCells.range(op))
  end

  describe "runs" do
    test "neighbouring cells travel in one op" do
      plan = Sheetshow.row([1, 2, 3], sheet: "Costs") |> Sheetshow.plan!()

      assert a1(plan) == ["Costs!A1:C1"]
    end

    test "a gap splits the row, so a write never clears what sits between" do
      cells = [Cell.new("A1", 1), Cell.new("B1", 2), Cell.new("D1", 4), Cell.new("G1", 7)]

      assert Sheetshow.plan!(cells, sheet: "Costs") |> a1() == [
               "Costs!A1:B1",
               "Costs!D1",
               "Costs!G1"
             ]
    end

    test "cells may arrive in any order" do
      cells = [Cell.new("C1", 3), Cell.new("A2", 4), Cell.new("A1", 1), Cell.new("B1", 2)]

      assert Sheetshow.plan!(cells, sheet: "Costs") |> a1() == ["Costs!A1:C1", "Costs!A2"]
    end

    test "rows and sheets come out in the order the cells named them" do
      cells =
        Sheetshow.row([1], sheet: "log") ++
          Sheetshow.row([2], row: 2, sheet: "Costs") ++
          Sheetshow.row([3], sheet: "Costs")

      assert Sheetshow.plan!(cells) |> a1() == ["log!A1", "Costs!A1", "Costs!A3"]
    end

    test "two cells at one coordinate are one cell, the last one winning" do
      cells = [Cell.new("A1", 1), Cell.new("A1", 9)]
      plan = Sheetshow.plan!(cells, sheet: "Costs")

      assert [%PutCells{cells: [%Cell{value: 9}]}] = plan
    end

    test "no cells, no plan" do
      assert Sheetshow.plan!([]) == []
    end
  end

  describe "sheets" do
    test "cells that name no sheet take the one given" do
      cells = [Cell.new("A1", 1), Cell.new("log!A1", 2)]

      assert Sheetshow.plan!(cells, sheet: "Costs") |> a1() == ["Costs!A1", "log!A1"]
    end

    test "a cell with nowhere to go is an error, pointing at the cell" do
      cell = Cell.new("B4", 1)

      assert {:error, %Error{reason: :missing_sheet, details: %{cell: ^cell}}} =
               Sheetshow.plan([cell])

      assert_raise Error, fn -> Sheetshow.plan!([cell]) end
    end

    test "sheets the spreadsheet does not have are added first" do
      cells =
        Sheetshow.row([1], sheet: "Costs") ++ Sheetshow.row([2], sheet: "log")

      assert [%AddSheet{title: "log"}, %PutCells{}, %PutCells{}] =
               Sheetshow.plan!(cells, existing_sheets: ["Costs"])
    end

    test "without existing_sheets the plan assumes the sheets are there" do
      cells = Sheetshow.row([1], sheet: "Costs")

      assert [%PutCells{}] = Sheetshow.plan!(cells)
      assert [%AddSheet{}, %PutCells{}] = Sheetshow.plan!(cells, existing_sheets: [])
    end
  end

  describe "styles" do
    test "a temporal value gets the format that makes it readable" do
      cells = [
        Cell.new("A1", ~D[2026-09-12]),
        Cell.new("B1", ~T[08:30:00]),
        Cell.new("C1", ~N[2026-09-12 08:30:00], %{number_format: "mmm yyyy"}),
        Cell.new("D1", 42)
      ]

      assert [%PutCells{cells: cells}] = Sheetshow.plan!(cells, sheet: "Costs")

      assert Enum.map(cells, & &1.style) == [
               %{number_format: "yyyy-mm-dd"},
               %{number_format: "hh:mm:ss"},
               %{number_format: "mmm yyyy"},
               %{}
             ]
    end

    test "widths and heights leave the cells for ops of their own" do
      cells = [
        Cell.new("A1", 1, %{col_width: 180, bold: true}),
        Cell.new("B1", 2, %{col_width: 180}),
        Cell.new("C1", 3, %{col_width: 60, row_height: 40})
      ]

      assert [%PutCells{cells: written} | dimensions] = Sheetshow.plan!(cells, sheet: "Costs")

      assert Enum.map(written, & &1.style) == [%{bold: true}, %{}, %{}]

      assert dimensions == [
               SetDimensions.new("Costs", :cols, 0..1, 180),
               SetDimensions.new("Costs", :cols, 2..2, 60),
               SetDimensions.new("Costs", :rows, 0..0, 40)
             ]
    end

    test "the last cell in reading order sets the size" do
      cells = [
        Cell.new("A1", 1, %{col_width: 180}),
        Cell.new("A2", 2, %{col_width: 60})
      ]

      assert [_, _, %SetDimensions{pixels: 60}] = Sheetshow.plan!(cells, sheet: "Costs")
    end
  end

  describe "validation" do
    test "a plan is only ever made of cells that can be written" do
      cells = [Cell.new("A1", 1), Cell.new("B1", 2, %{bolt: true})]

      assert {:error, %Error{reason: :invalid_style, details: details}} = Sheetshow.plan(cells)
      assert details.key == :bolt
      assert details.cell.coord.col == 1

      assert {:error, %Error{reason: :invalid_value}} =
               Sheetshow.plan([Cell.new("A1", {:formula, "SUM(A1)"})], sheet: "Costs")

      assert {:error, %Error{reason: :invalid_cell}} = Sheetshow.plan([%{value: 1}])
    end

    test "an option that is not one raises" do
      assert_raise ArgumentError, fn -> Sheetshow.plan([], existing_sheet: ["Costs"]) end
    end
  end

  test "a plan writes what the cells said, read back through the memory backend" do
    cells =
      Sheetshow.stack([
        Sheetshow.row(["Item", "Cost"], style: %{bold: true}),
        Sheetshow.records([%{item: "Rent", cost: 1000}, %{item: "Food"}], [:item, :cost])
      ])
      |> Sheetshow.put_sheet("Costs")

    plan = Sheetshow.plan!(cells, existing_sheets: [])
    memory = Memory.run!(plan, Memory.new())

    assert Memory.read!("Costs", memory) |> Sheetshow.to_rows() == [
             ["Item", "Cost"],
             ["Rent", 1000],
             ["Food", nil]
           ]
  end
end
