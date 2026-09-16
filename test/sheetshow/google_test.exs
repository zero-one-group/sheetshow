defmodule Sheetshow.GoogleTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.Google

  alias Sheetshow.{Cell, Error, Google}
  alias Sheetshow.Op.{AddSheet, AppendRows, DeleteRows, DeleteSheet, PutCells, SetDimensions}

  # One sheet called Costs, id 0, as a fresh spreadsheet has.
  defp encode(op), do: Google.encode!(List.wrap(op), %{"Costs" => 0})

  defp added(%{requests: [%{addSheet: %{properties: %{sheetId: id}}} | _]}), do: id

  defp values(op) do
    %{requests: [%{updateCells: %{rows: [%{values: values}]}}]} = encode(op)
    values
  end

  describe "cells" do
    test "a value becomes the variant Sheets keeps it in" do
      cells = [
        Cell.new("A1", 42),
        Cell.new("B1", "text"),
        Cell.new("C1", true),
        Cell.new("D1", {:formula, "=A1*2"}),
        Cell.new("E1", ~D[1970-01-01]),
        Cell.new("F1")
      ]

      assert values(PutCells.new(cells, "Costs")) == [
               %{userEnteredValue: %{numberValue: 42}},
               %{userEnteredValue: %{stringValue: "text"}},
               %{userEnteredValue: %{boolValue: true}},
               %{userEnteredValue: %{formulaValue: "=A1*2"}},
               %{userEnteredValue: %{numberValue: 25_569}},
               %{}
             ]
    end

    test "a style becomes a cell format" do
      style = %{
        bold: true,
        italic: false,
        font_size: 12,
        font_family: "Roboto",
        color: "#FF8800",
        background: "#FFFFFF",
        horizontal: :center,
        vertical: :middle,
        wrap: :wrap,
        number_format: "0.00%"
      }

      assert [%{userEnteredFormat: format}] =
               values(PutCells.new([Cell.new("A1", 0.22, style)], "Costs"))

      assert format == %{
               textFormat: %{
                 bold: true,
                 italic: false,
                 fontSize: 12,
                 fontFamily: "Roboto",
                 foregroundColorStyle: %{rgbColor: %{red: 1.0, green: 136 / 255, blue: 0.0}}
               },
               backgroundColorStyle: %{rgbColor: %{red: 1.0, green: 1.0, blue: 1.0}},
               horizontalAlignment: "CENTER",
               verticalAlignment: "MIDDLE",
               wrapStrategy: "WRAP",
               numberFormat: %{type: "NUMBER", pattern: "0.00%"}
             }
    end

    test "the number format type comes from what the cell holds" do
      for {value, type} <- [
            {~D[2026-01-01], "DATE"},
            {~N[2026-01-01 08:30:00], "DATE_TIME"},
            {~T[08:30:00], "TIME"},
            {1, "NUMBER"},
            {"text", "NUMBER"}
          ] do
        cell = Cell.new("A1", value, %{number_format: "p"})

        assert [%{userEnteredFormat: %{numberFormat: %{type: ^type, pattern: "p"}}}] =
                 values(PutCells.new([cell], "Costs"))
      end
    end

    test "writing a cell replaces value and format together" do
      %{requests: [%{updateCells: update}]} = encode(PutCells.new([Cell.new("A1", 1)], "Costs"))

      assert update.fields == "userEnteredValue,userEnteredFormat"
      assert update.start == %{sheetId: 0, rowIndex: 0, columnIndex: 0}
    end

    test "a run starts where its first cell is" do
      op = PutCells.new(Sheetshow.row([1, 2], row: 3, col: 4), "Costs")
      %{requests: [%{updateCells: update}]} = encode(op)

      assert update.start == %{sheetId: 0, rowIndex: 3, columnIndex: 4}
      assert length(hd(update.rows).values) == 2
    end
  end

  describe "sheets" do
    test "a new sheet's id comes from its title, and the ops after it use it" do
      plan = [AddSheet.new("log"), PutCells.new(Sheetshow.row([1]), "log")]
      id = Google.sheet_id("log")

      assert %{requests: [add, put]} = Google.encode!(plan, %{"Costs" => 0})
      assert add == %{addSheet: %{properties: %{sheetId: id, title: "log"}}}
      assert put.updateCells.start.sheetId == id
    end

    test "the same title always asks for the same id" do
      assert Google.sheet_id("log") == Google.sheet_id("log")
      refute Google.sheet_id("log") == Google.sheet_id("Costs")
    end

    test "two writers adding differently named tabs at once do not collide" do
      # Both plan against the same snapshot, which is exactly the case the
      # lowest-free-id scheme used to break.
      snapshot = %{"Costs" => 0}

      assert added(Google.encode!([AddSheet.new("one")], snapshot)) !=
               added(Google.encode!([AddSheet.new("two")], snapshot))
    end

    test "an id already in use is stepped over" do
      id = Google.sheet_id("log")

      assert Google.sheet_id("log", %{"Costs" => id}) == id + 1
      assert Google.sheet_id("log", %{"a" => id, "b" => id + 1}) == id + 2
    end

    test "an op for a sheet that is not there is an error, not half a batch" do
      plan = [
        PutCells.new(Sheetshow.row([1]), "Costs"),
        PutCells.new(Sheetshow.row([1]), "log")
      ]

      assert {:error, %Error{reason: :unknown_sheet, details: details}} =
               Google.encode(plan, %{"Costs" => 0})

      assert details == %{sheet: "log", sheets: ["Costs"]}
    end

    test "adding a sheet that is already there is an error" do
      assert {:error, %Error{reason: :duplicate_sheet}} =
               Google.encode([AddSheet.new("Costs")], %{"Costs" => 0})

      assert_raise Error, fn -> Google.encode!([AddSheet.new("Costs")], %{"Costs" => 0}) end
    end
  end

  describe "the other ops" do
    test "appended rows spell out their gaps, because they start at column A" do
      op = AppendRows.new([Cell.new("B1", "x"), Cell.new("A3", "y")], "Costs")

      assert %{requests: [%{appendCells: append}]} = encode(op)
      assert append.sheetId == 0
      assert append.fields == "userEnteredValue,userEnteredFormat"

      assert append.rows == [
               %{values: [%{}, %{userEnteredValue: %{stringValue: "x"}}]},
               %{},
               %{values: [%{userEnteredValue: %{stringValue: "y"}}]}
             ]
    end

    test "appending nothing asks for nothing" do
      assert %{requests: [%{appendCells: %{rows: []}}]} = encode(AppendRows.new([], "Costs"))
    end

    test "inclusive rows become a half-open range" do
      assert %{requests: [%{deleteDimension: %{range: range}}]} =
               encode(DeleteRows.new("Costs", 2..4))

      assert range == %{sheetId: 0, dimension: "ROWS", startIndex: 2, endIndex: 5}
    end

    test "dimensions name their axis and carry a field mask of their own" do
      assert %{requests: [%{updateDimensionProperties: cols}]} =
               encode(SetDimensions.new("Costs", :cols, 0..1, 180))

      assert cols.range == %{sheetId: 0, dimension: "COLUMNS", startIndex: 0, endIndex: 2}
      assert cols.properties == %{pixelSize: 180}
      assert cols.fields == "pixelSize"

      assert %{requests: [%{updateDimensionProperties: rows}]} =
               encode(SetDimensions.new("Costs", :rows, 2..2, 40))

      assert rows.range.dimension == "ROWS"
    end
  end

  describe "deleting a sheet" do
    test "asks for it by the number Google knows it by" do
      assert %{requests: [%{deleteSheet: %{sheetId: 0}}]} = encode(DeleteSheet.new("Costs"))
    end

    test "and the ops after it cannot use it any more" do
      plan = [DeleteSheet.new("Costs"), PutCells.new(Sheetshow.row([1]), "Costs")]

      assert {:error, %Error{reason: :unknown_sheet}} = Google.encode(plan, %{"Costs" => 0})
    end

    test "a sheet that is not there cannot go" do
      assert {:error, %Error{reason: :unknown_sheet}} =
               Google.encode([DeleteSheet.new("log")], %{"Costs" => 0})
    end
  end

  test "an empty plan asks for nothing" do
    assert Google.encode!([], %{}) == %{requests: []}
  end

  test "what comes out is JSON, with the planner's work in it" do
    cells = [Cell.new("A1", ~D[2026-09-12]), Cell.new("C1", "note")]
    body = cells |> Sheetshow.plan!(sheet: "Costs") |> Google.encode!(%{"Costs" => 0})

    assert [%{"updateCells" => date}, %{"updateCells" => note}] =
             body |> JSON.encode!() |> JSON.decode!() |> Map.fetch!("requests")

    assert get_in(date, ["rows", Access.at(0), "values", Access.at(0)]) == %{
             "userEnteredValue" => %{"numberValue" => 46_277},
             "userEnteredFormat" => %{
               "numberFormat" => %{"type" => "DATE", "pattern" => "yyyy-mm-dd"}
             }
           }

    assert note["start"]["columnIndex"] == 2
  end
end
