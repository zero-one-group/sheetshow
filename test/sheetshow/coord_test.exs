defmodule Sheetshow.CoordTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.Coord

  alias Sheetshow.Coord

  test "to_a1 and from_a1 round-trip, sheet or not" do
    for sheet <- [nil, "Costs", "Q1 costs", "Tab1"],
        row <- [0, 9, 999],
        col <- [0, 25, 26, 702] do
      coord = Coord.new(row, col, sheet)
      assert {:ok, ^coord} = Coord.from_a1(Coord.to_a1(coord))
    end
  end

  test "from_a1 rejects ranges, sheet-only strings and malformed input" do
    for bad <- ["", "A", "1", "A0", "A1:B2", "A:A", "Costs!", "'Costs'", "!A1"] do
      assert {:error, %Sheetshow.Error{reason: :invalid_a1}} = Coord.from_a1(bad)
    end

    assert_raise Sheetshow.Error, fn -> Coord.from_a1!("A0") end
  end

  test "new rejects negative positions" do
    assert_raise FunctionClauseError, fn -> Coord.new(-1, 0) end
  end

  test "shift refuses to leave the sheet" do
    assert_raise ArgumentError, fn -> Coord.shift(Coord.new(0, 0), -1, 0) end
  end

  test "compare orders by sheet, then row, then col" do
    coords = [
      Coord.new(0, 0, "bravo"),
      Coord.new(1, 0, "alpha"),
      Coord.new(0, 1, "alpha"),
      Coord.new(0, 0, "alpha"),
      Coord.new(5, 5)
    ]

    assert Enum.sort(coords, Coord) |> Enum.map(&Coord.to_a1/1) ==
             ["F6", "alpha!A1", "alpha!B1", "alpha!A2", "bravo!A1"]
  end
end
