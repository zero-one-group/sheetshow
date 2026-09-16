defmodule Sheetshow.OpTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.Op
  doctest Sheetshow.Op.AddSheet
  doctest Sheetshow.Op.AppendRows
  doctest Sheetshow.Op.DeleteRows
  doctest Sheetshow.Op.DeleteSheet
  doctest Sheetshow.Op.PutCells
  doctest Sheetshow.Op.SetDimensions

  alias Sheetshow.Cell
  alias Sheetshow.Op
  alias Sheetshow.Op.{AddSheet, AppendRows, DeleteRows, DeleteSheet, PutCells, SetDimensions}

  describe "PutCells" do
    test "takes the sheet from the cells and leaves it off their coordinates" do
      op = PutCells.new(Sheetshow.row([1, 2], sheet: "Costs"))

      assert op.sheet == "Costs"
      assert Enum.map(op.cells, & &1.coord.sheet) == [nil, nil]
      assert Enum.map(op.cells, & &1.value) == [1, 2]
    end

    test "an explicit sheet wins over the cells'" do
      cells = Sheetshow.row([1], sheet: "Costs")
      assert PutCells.new(cells, "log").sheet == "log"
    end

    test "cells are sorted left to right" do
      cells = [Cell.new("C1", 3), Cell.new("A1", 1), Cell.new("B1", 2)]

      assert PutCells.new(cells, "Costs") |> Map.fetch!(:cells) |> Enum.map(& &1.value) ==
               [1, 2, 3]
    end

    test "row, col and range describe the run" do
      op = PutCells.new(Sheetshow.row([1, 2, 3], row: 4, col: 1), "Costs")

      assert PutCells.row(op) == 4
      assert PutCells.col(op) == 1
      assert Sheetshow.Range.to_a1(PutCells.range(op)) == "Costs!B5:D5"
    end

    test "a run is one row of neighbouring cells, written once each" do
      for bad <- [
            [Cell.new("A1", 1), Cell.new("C1", 3)],
            [Cell.new("A1", 1), Cell.new("A2", 2)],
            [Cell.new("A1", 1), Cell.new("A1", 2)]
          ] do
        assert_raise ArgumentError, fn -> PutCells.new(bad, "Costs") end
      end
    end

    test "the sheet must be knowable and single" do
      assert_raise ArgumentError, fn -> PutCells.new(Sheetshow.row([1])) end
      assert_raise ArgumentError, fn -> PutCells.new([], "Costs") end

      mixed = [Cell.new("Costs!A1", 1), Cell.new("log!B1", 2)]
      assert_raise ArgumentError, fn -> PutCells.new(mixed) end
    end
  end

  describe "AppendRows" do
    test "keeps rows as offsets from the append point" do
      op = AppendRows.new(Sheetshow.rows([["a"], ["b"]], sheet: "log"))

      assert op.sheet == "log"
      assert Enum.map(op.cells, &{&1.coord.row, &1.coord.sheet}) == [{0, nil}, {1, nil}]
      assert AppendRows.height(op) == 2
    end

    test "an empty op adds nothing" do
      assert AppendRows.new([], "log") == %AppendRows{sheet: "log", cells: []}
      assert AppendRows.height(AppendRows.new([], "log")) == 0
    end

    test "without cells there is no sheet to find" do
      assert_raise ArgumentError, fn -> AppendRows.new(Sheetshow.row([1])) end
    end
  end

  describe "DeleteRows and SetDimensions" do
    test "ranges ascend by one from row or column zero" do
      assert DeleteRows.count(DeleteRows.new("log", 2..4)) == 3

      assert_raise FunctionClauseError, fn -> DeleteRows.new("log", 4..2//-1) end
      assert_raise FunctionClauseError, fn -> DeleteRows.new("log", 0..4//2) end
      assert_raise FunctionClauseError, fn -> SetDimensions.new("Costs", :cols, 0..1, 0) end
      assert_raise FunctionClauseError, fn -> SetDimensions.new("Costs", :cols, 3..1//-1, 100) end
    end
  end

  test "every op names its sheet" do
    ops = [
      AddSheet.new("Costs"),
      DeleteSheet.new("Costs"),
      AppendRows.new([], "Costs"),
      DeleteRows.new("Costs", 0..0),
      PutCells.new(Sheetshow.row([1]), "Costs"),
      SetDimensions.new("Costs", :rows, 0..0, 40)
    ]

    assert Enum.map(ops, &Op.sheet/1) == List.duplicate("Costs", 6)
    assert Enum.all?(ops, &Op.op?/1)
    assert Enum.map(ops, & &1.__struct__) |> Enum.sort() == Enum.sort(Op.modules())
    refute Op.op?(%{sheet: "Costs"})
  end
end
