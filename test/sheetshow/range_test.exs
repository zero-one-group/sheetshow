defmodule Sheetshow.RangeTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.Range

  alias Sheetshow.{Coord, Range}

  @canonical [
    "A1",
    "A1:C3",
    "B4:B9",
    "A:A",
    "A:C",
    "B:B",
    "1:1",
    "2:3",
    "A2:F",
    "C5:C",
    "Costs!A1:C3",
    "Costs!A:A",
    "Costs",
    "'Q1 costs'!B2:D",
    "'Q1 costs'",
    "'Tab1'!A1",
    "'Tab1'"
  ]

  test "canonical strings survive a from_a1 / to_a1 round-trip unchanged" do
    for a1 <- @canonical do
      assert a1 |> Range.from_a1!() |> Range.to_a1() == a1
    end
  end

  test "non-canonical spellings normalise" do
    for {input, canonical} <- [
          {"c3:a1", "A1:C3"},
          {"$A$1:$C$3", "A1:C3"},
          {"B4:B4", "B4"},
          {"C:A", "A:C"},
          {"3:2", "2:3"},
          {"Costs!A1", "Costs!A1"},
          {"'Costs'!A1", "Costs!A1"},
          {"Tab1", "TAB1"}
        ] do
      assert input |> Range.from_a1!() |> Range.to_a1() == canonical
    end
  end

  test "an unquoted reference-like name is a reference, so Tab1 is a cell" do
    assert {:ok, %Range{sheet: nil, start_row: 0, start_col: 13_547, end_row: 0, end_col: 13_547}} =
             Range.from_a1("Tab1")
  end

  test "from_a1 errors" do
    for bad <- [
          "",
          "A0",
          "A1:",
          ":A1",
          "A1:B2:C3",
          "Costs!",
          "!A1",
          "A1:B0",
          "'Costs",
          "A:B2",
          "1:B2"
        ] do
      assert {:error, %Sheetshow.Error{reason: :invalid_a1}} = Range.from_a1(bad)
    end

    assert_raise Sheetshow.Error, fn -> Range.from_a1!("A0") end
  end

  test "to_a1 refuses what A1 notation cannot say" do
    assert_raise ArgumentError, fn -> Range.to_a1(%Range{}) end
    assert_raise ArgumentError, fn -> Range.to_a1(%Range{start_row: 1}) end
  end

  test "new needs ascending, non-negative, step-one ranges" do
    assert_raise FunctionClauseError, fn -> Range.new(nil, 3..1//-1, 0..0) end
    assert_raise FunctionClauseError, fn -> Range.new(nil, 0..2//2, 0..0) end
  end

  test "bounding of one cell is that cell" do
    coord = Coord.new(2, 2, "S")
    assert Range.bounding([coord]) == Range.new("S", 2..2, 2..2)
    assert Range.bounding([%{coord: coord}]) == Range.new("S", 2..2, 2..2)
  end

  test "bounding rejects mixed sheets" do
    assert_raise ArgumentError, fn ->
      Range.bounding([Coord.new(0, 0, "a"), Coord.new(0, 0, "b")])
    end
  end

  test "contains? respects unbounded ends and sheet identity" do
    whole_col = Range.from_a1!("B:B")
    assert Range.contains?(whole_col, Coord.new(1_000_000, 1))
    refute Range.contains?(whole_col, Coord.new(0, 0))
    refute Range.contains?(whole_col, Coord.new(0, 1, "Costs"))
  end
end
