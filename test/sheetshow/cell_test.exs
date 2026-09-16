defmodule Sheetshow.CellTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.Cell

  alias Sheetshow.{Cell, Coord}

  test "new accepts a Coord or an A1 string and defaults value and style" do
    assert Cell.new(Coord.new(0, 0)) == %Cell{
             coord: Coord.new(0, 0),
             value: nil,
             style: %{},
             meta: %{}
           }

    assert Cell.new("B2") == Cell.new(Coord.new(1, 1))
    assert_raise Sheetshow.Error, fn -> Cell.new("A0") end
  end

  test "a cell needs a coordinate" do
    assert_raise ArgumentError, fn -> struct!(Cell, value: 1) end
  end

  test "validate covers value, style and the coordinate, and points at the cell" do
    cell = Cell.new("A1", {:formula, "SUM(A2:A9)"})

    assert {:error, %Sheetshow.Error{reason: :invalid_value, details: %{cell: ^cell}}} =
             Cell.validate(cell)

    cell = Cell.new("A1", 1, %{font_size: -2})

    assert {:error,
            %Sheetshow.Error{reason: :invalid_style, details: %{key: :font_size, cell: ^cell}}} =
             Cell.validate(cell)

    assert {:error, %Sheetshow.Error{reason: :invalid_cell}} =
             Cell.validate(%{coord: Coord.new(0, 0)})

    assert {:error, %Sheetshow.Error{reason: :invalid_cell}} = Cell.validate(%Cell{coord: "A1"})

    assert Cell.valid?(Cell.new("A1", ~D[2026-09-12], %{number_format: "d mmm yyyy"}))
  end

  test "put_style merges, shift moves, put_sheet places" do
    cell = Cell.new("Costs!B2", 1, %{bold: true})

    assert Cell.put_style(cell, %{italic: true}).style == %{bold: true, italic: true}
    assert Cell.shift(cell, -1, 1).coord == Coord.new(0, 2, "Costs")
    assert Cell.put_sheet(cell, nil).coord == Coord.new(1, 1)
    assert_raise ArgumentError, fn -> Cell.shift(cell, -2, 0) end
  end

  test "meta is carried along untouched" do
    cell = %{Cell.new("A1", 1) | meta: %{formatted: "1.00"}}
    assert Cell.put_style(cell, %{bold: true}).meta == %{formatted: "1.00"}
    assert Cell.shift(cell, 1, 1).meta == %{formatted: "1.00"}
  end
end
