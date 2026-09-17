defmodule SheetshowTest do
  use ExUnit.Case, async: true
  doctest Sheetshow

  import Sheetshow
  alias Sheetshow.{Cell, Coord}

  defmodule Cost do
    defstruct [:item, :cost]
  end

  defp a1s(cells), do: Enum.map(cells, &Coord.to_a1(&1.coord))

  describe "builders" do
    test "row, col and table honour row, col, sheet and style" do
      opts = [row: 1, col: 2, sheet: "S", style: %{bold: true}]

      assert a1s(row([1, 2], opts)) == ["S!C2", "S!D2"]
      assert a1s(col([1, 2], opts)) == ["S!C2", "S!C3"]
      assert a1s(rows([[1, 2], [3]], opts)) == ["S!C2", "S!D2", "S!C3"]
      assert Enum.all?(rows([[1, 2], [3]], opts), &(&1.style == %{bold: true}))
      assert row([]) == []
    end

    test "records take structs, tolerate missing keys and label headers" do
      records = [%Cost{item: "Rent", cost: 1000}, %{item: "Food"}]

      assert to_rows(records(records, [:cost, :item])) ==
               [[1000, "Rent"], [nil, "Food"]]

      assert to_rows(records(records, [:item, :cost], header: ["Item", "Cost"])) ==
               [["Item", "Cost"], ["Rent", 1000], ["Food", nil]]

      assert records([], [:item]) == []
      assert to_rows(records([], [:item], header: true)) == [["item"]]
    end

    test "header: false is the same as leaving the header out" do
      assert to_rows(records([%{a: 1}], [:a], header: false)) == [[1]]
    end

    test "an option a builder does not take is a mistake worth raising on" do
      assert_raise ArgumentError, ~r/unknown keys \[:sheets\]/, fn -> row([1], sheets: "S") end
      assert_raise ArgumentError, ~r/unknown keys \[:styl\]/, fn -> col([1], styl: %{}) end
      assert_raise ArgumentError, ~r/unknown keys \[:rows\]/, fn -> rows([[1]], rows: 2) end

      assert_raise ArgumentError, ~r/unknown keys \[:headers\]/, fn ->
        records([%{a: 1}], [:a], headers: true)
      end
    end
  end

  describe "to_rows" do
    test "is relative to the bounding range and the last duplicate wins" do
      cells = [Cell.new("C3", 1), Cell.new("B2", 2), Cell.new("C3", 3)]
      assert to_rows(cells) == [[2, nil], [nil, 3]]
    end

    test "inverts rows for any table anchored at the origin" do
      table = [["a", 1, true], [nil, ~D[2026-09-12], 2.5], [{:formula, "=A1"}]]

      assert table |> rows() |> to_rows() == [
               Enum.at(table, 0),
               Enum.at(table, 1),
               [{:formula, "=A1"}, nil, nil]
             ]
    end

    test "refuses mixed sheets" do
      assert_raise ArgumentError, fn -> to_rows([Cell.new("a!A1"), Cell.new("b!A1")]) end
    end

    test "no cells is no rows, so a read of an empty range pipes straight in" do
      assert to_rows([]) == []

      workbook = Sheetshow.Workbook.memory(["Costs"])
      assert read_cells!("Costs!A1:C3", workbook) |> to_rows() == []
      assert read_rows!("Costs!A1:C3", workbook) == []
    end
  end

  describe "stack and beside" do
    test "below stacks by extent and keeps each group's internal offsets" do
      header = row(["h1", "h2"])
      indented = row([1, 2], row: 2, col: 1)

      assert a1s(stack([header, indented])) == ["A1", "B1", "B4", "C4"]
      assert a1s(stack(header, indented)) == ["A1", "B1", "B4", "C4"]
    end

    test "right does the same across" do
      assert a1s(beside([col([1, 2]), col([3], row: 1)])) == [
               "A1",
               "A2",
               "B2"
             ]

      assert a1s(beside(col([1]), col([2]))) == ["A1", "B1"]
    end

    test "empty groups take no room" do
      cells = row([1])
      assert stack([[], cells, [], cells]) |> a1s() == ["A1", "A2"]
      assert beside([[], cells, []]) |> a1s() == ["A1"]
      assert stack([]) == []
    end

    test "sheets pass through untouched" do
      cells = stack([row([1], sheet: "a"), row([2], sheet: "b")])
      assert a1s(cells) == ["a!A1", "b!A2"]
    end
  end

  describe "padding" do
    test "holds room with one empty cell on the same sheet" do
      padded = row([1, 2], sheet: "S") |> pad_below(3)
      assert a1s(padded) == ["S!A1", "S!B1", "S!A4"]
      assert List.last(padded).value == nil

      assert row([1], sheet: "S") |> pad_right(2) |> a1s() == ["S!A1", "S!C1"]

      assert a1s(stack([pad_below(row([1])), row([2])])) == [
               "A1",
               "A2",
               "A3"
             ]
    end

    test "padding nothing still takes room" do
      assert pad_below([], 2) |> max_row() == 1
    end
  end

  describe "bulk edits" do
    test "shift, put_sheet and put_style map over every cell" do
      cells = row([1, 2], style: %{bold: true})

      assert cells |> shift(1, 1) |> a1s() == ["B2", "C2"]
      assert cells |> put_sheet("S") |> a1s() == ["S!A1", "S!B1"]

      assert cells |> put_style(%{italic: true}) |> Enum.map(& &1.style) |> Enum.uniq() == [
               %{bold: true, italic: true}
             ]

      assert shift([], 1, 1) == []
    end

    test "max_row and max_col" do
      cells = rows([[1, 2, 3], [4]])
      assert {max_row(cells), max_col(cells)} == {1, 2}
      assert {max_row([]), max_col([])} == {nil, nil}
    end
  end
end
