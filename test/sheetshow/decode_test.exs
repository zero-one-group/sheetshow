defmodule Sheetshow.DecodeTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.CellError

  alias Sheetshow.{
    Cell,
    CellError,
    Workbook,
    Coord,
    Error,
    Fixtures,
    Google,
    Memory,
    TestServer,
    Token
  }

  defp answer(values, block \\ %{}) do
    %{
      "sheets" => [
        %{
          "properties" => %{"title" => "Costs"},
          "data" => [Map.merge(%{"rowData" => [%{"values" => values}]}, block)]
        }
      ]
    }
  end

  defp one(data) do
    [cell] = Google.decode(answer([data]))
    cell
  end

  describe "values" do
    test "come back as what was entered, not as what Sheets made of it" do
      cell =
        one(%{
          "userEnteredValue" => %{"formulaValue" => "=1+1"},
          "effectiveValue" => %{"numberValue" => 2},
          "formattedValue" => "2"
        })

      assert cell.value == {:formula, "=1+1"}
      assert cell.meta == %{formatted: "2", effective: 2}
    end

    test "every kind survives the trip" do
      for {entered, expected} <- [
            {%{"numberValue" => 42}, 42},
            {%{"stringValue" => "text"}, "text"},
            {%{"boolValue" => true}, true},
            {%{"formulaValue" => "=A1"}, {:formula, "=A1"}}
          ] do
        assert one(%{"userEnteredValue" => entered}).value == expected
      end
    end

    test "a serial number is a date when its format says it is" do
      for {type, expected} <- [
            {"DATE", ~D[2026-09-12]},
            {"DATE_TIME", ~N[2026-09-12 00:00:00]},
            {"TIME", ~T[00:00:00]}
          ] do
        cell =
          one(%{
            "userEnteredValue" => %{"numberValue" => 46_277},
            "effectiveFormat" => %{"numberFormat" => %{"type" => type, "pattern" => "p"}}
          })

        assert cell.value == expected
      end
    end

    test "and stays a number when it does not" do
      cell =
        one(%{
          "userEnteredValue" => %{"numberValue" => 46_277},
          "effectiveFormat" => %{"numberFormat" => %{"type" => "NUMBER"}}
        })

      assert cell.value == 46_277
    end

    test "an error is never a value: it is what the formula came to" do
      cell =
        one(%{
          "userEnteredValue" => %{"formulaValue" => "=1/0"},
          "effectiveValue" => %{
            "errorValue" => %{"type" => "DIVIDE_BY_ZERO", "message" => "cannot be zero"}
          },
          "formattedValue" => "#DIV/0!"
        })

      assert cell.value == {:formula, "=1/0"}
      assert cell.meta.formatted == "#DIV/0!"
      assert cell.meta.effective == %CellError{type: :divide_by_zero, message: "cannot be zero"}
    end
  end

  describe "the grid" do
    test "cells land where the block says they start" do
      answer =
        answer([%{"userEnteredValue" => %{"numberValue" => 1}}], %{
          "startRow" => 4,
          "startColumn" => 2
        })

      assert [cell] = Google.decode(answer)
      assert Coord.to_a1(cell.coord) == "Costs!C5"
    end

    test "a missing start means the top left, which is how Google leaves it out" do
      assert [cell] = Google.decode(answer([%{"userEnteredValue" => %{"numberValue" => 1}}]))
      assert Coord.to_a1(cell.coord) == "Costs!A1"
    end

    test "empty cells are not cells, but a styled one is" do
      values = [
        %{"userEnteredValue" => %{"numberValue" => 1}},
        %{},
        %{"userEnteredFormat" => %{"backgroundColor" => %{}, "textFormat" => %{"bold" => true}}}
      ]

      assert [first, styled] = Google.decode(answer(values))
      assert first.value == 1
      assert Coord.to_a1(styled.coord) == "Costs!C1"
      assert styled.value == nil
      assert styled.style == %{bold: true}
    end

    test "nothing at all is no cells" do
      assert Google.decode(%{}) == []
      assert Google.decode(%{"sheets" => [%{"properties" => %{"title" => "Costs"}}]}) == []
    end

    # A cell in a column somebody formatted as a whole comes back with an
    # effectiveFormat and nothing else; nothing was entered there and nothing
    # was formatted, so it is as empty as `{}`.
    test "a cell that only inherits a format is not a cell" do
      values = [
        %{
          "effectiveFormat" => %{"numberFormat" => %{"type" => "DATE", "pattern" => "yyyy-mm-dd"}}
        },
        %{"userEnteredValue" => %{"numberValue" => 1}}
      ]

      assert [only] = Google.decode(answer(values))
      assert Coord.to_a1(only.coord) == "Costs!B1"
    end
  end

  test "a colour component Google left out is zero" do
    data = %{
      "userEnteredValue" => %{"stringValue" => "x"},
      "userEnteredFormat" => %{
        "backgroundColorStyle" => %{"rgbColor" => %{"red" => 1}},
        "textFormat" => %{
          "foregroundColorStyle" => %{"rgbColor" => %{"blue" => 1, "green" => 0.5}}
        }
      }
    }

    assert one(data).style == %{background: "#FF0000", color: "#0080FF"}
  end

  test "a theme colour is not a colour we can name, so it is left out" do
    data = %{
      "userEnteredValue" => %{"stringValue" => "x"},
      "userEnteredFormat" => %{"backgroundColorStyle" => %{"themeColor" => "ACCENT1"}}
    }

    assert one(data).style == %{}
  end

  test "every style key makes the round trip it was encoded from" do
    style = %{
      bold: true,
      italic: false,
      underline: true,
      strikethrough: true,
      font_size: 12,
      font_family: "Roboto",
      color: "#FF8800",
      background: "#FFFFFF",
      horizontal: :center,
      vertical: :middle,
      wrap: :wrap,
      number_format: "0.00%"
    }

    assert Enum.sort(Map.keys(style)) ==
             Enum.sort(Sheetshow.Style.keys() -- [:col_width, :row_height])

    written = Cell.new("Costs!A1", 0.22, style)
    op = Sheetshow.Op.PutCells.new([written], "Costs")

    %{requests: [%{updateCells: %{rows: [%{values: [encoded]}]}}]} =
      Google.encode!([op], %{"Costs" => 0})

    data = %{
      "userEnteredValue" => %{"numberValue" => 0.22},
      "userEnteredFormat" => stringify(encoded.userEnteredFormat)
    }

    assert [read] = Google.decode(answer([data]))
    assert read.style == written.style
  end

  test "a style makes the round trip it was encoded from" do
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

    written = Cell.new("Costs!A1", 0.22, style)
    op = Sheetshow.Op.PutCells.new([written], "Costs")

    %{requests: [%{updateCells: %{rows: [%{values: [encoded]}]}}]} =
      Google.encode!([op], %{"Costs" => 0})

    # What the encoder sends is what a read gives back, spelled as Google spells it.
    data = %{
      "userEnteredValue" => %{"numberValue" => 0.22},
      "userEnteredFormat" => stringify(encoded.userEnteredFormat)
    }

    assert [read] = Google.decode(answer([data]))
    assert read.value == written.value
    assert read.style == written.style
  end

  defp stringify(%{} = map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), stringify(value)} end)
  end

  defp stringify(other), do: other

  describe "the answer recorded from Google" do
    test "decodes to exactly what the integration test wrote" do
      answer = Fixtures.read("values")

      assert answer,
             "test/fixtures/values.json is missing; record it with " <>
               "SHEETSHOW_RECORD_FIXTURES=1 mix check.all"

      cells = Google.decode(answer)

      # Real serial numbers, not the round ones a hand-written fixture would
      # have: 46277.354166666664 has to come back as half past eight exactly.
      assert Enum.map(cells, & &1.value) == [
               "text",
               42,
               2.5,
               true,
               ~D[2026-09-12],
               ~N[2026-09-12 08:30:00],
               ~T[08:30:00]
             ]

      assert Enum.map(cells, & &1.meta.formatted) == [
               "text",
               "42",
               "2.5",
               "TRUE",
               "2026-09-12",
               "2026-09-12 08:30:00",
               "08:30:00"
             ]

      # Google leaves startRow and startColumn out when they are zero.
      assert Enum.map(cells, &Sheetshow.Coord.to_a1(%{&1.coord | sheet: nil})) ==
               ~w(A1 B1 C1 D1 E1 F1 G1)
    end

    test "and the formats the planner chose came back unchanged" do
      cells = "values" |> Fixtures.read() |> Google.decode()

      assert Enum.map(cells, & &1.style) == [
               %{},
               %{},
               %{},
               %{},
               %{number_format: "yyyy-mm-dd"},
               %{number_format: "yyyy-mm-dd hh:mm:ss"},
               %{number_format: "hh:mm:ss"}
             ]
    end
  end

  describe "read" do
    defp workbook(url) do
      Workbook.google("1AbC",
        base_url: url,
        token: Token.new("ya29.abc", DateTime.add(DateTime.utc_now(), 3600, :second))
      )
    end

    test "asks for one range and the fields that make it decodable" do
      body = ~s({"sheets":[{"properties":{"title":"Costs"},"data":[{"rowData":[{"values":[
               {"userEnteredValue":{"stringValue":"Rent"}}]}]}]}]})

      url = TestServer.start([{200, body}])

      assert {:ok, [cell]} = Sheetshow.read_cells("Costs!A1:B2", workbook(url))
      assert cell.value == "Rent"

      assert_receive {:request, request}
      assert request.path == "/v4/spreadsheets/1AbC"
      assert request.query["ranges"] == "Costs!A1:B2"
      assert request.query["fields"] == Google.read_fields()
    end

    test "takes a range struct as well as A1" do
      url = TestServer.start([{200, ~s({"sheets":[]})}])
      range = Sheetshow.Range.new("Costs", 0..1, 0..1)

      assert {:ok, []} = Sheetshow.read_cells(range, workbook(url))
      assert_receive {:request, %{query: %{"ranges" => "Costs!A1:B2"}}}
    end

    test "a range needs a sheet, and a bad one never leaves the house" do
      workbook = workbook("http://127.0.0.1:1")

      assert {:error, %Error{reason: :invalid_range}} = Sheetshow.read_cells("A1:B2", workbook)
      assert {:error, %Error{reason: :invalid_a1}} = Sheetshow.read_cells("A0", workbook)
      assert_raise Error, fn -> Sheetshow.read_cells!("A1:B2", workbook) end
    end

    test "what comes back is what the memory backend would have given" do
      cells = Sheetshow.rows([["Item", "Cost"], ["Rent", 1000]], sheet: "Costs")
      plan = Sheetshow.plan!(cells, existing_sheets: [])
      remembered = Memory.read!("Costs", Memory.run!(plan, Memory.new()))

      body =
        JSON.encode!(
          answer([
            %{"userEnteredValue" => %{"stringValue" => "Item"}},
            %{"userEnteredValue" => %{"stringValue" => "Cost"}}
          ])
        )

      url = TestServer.start([{200, body}])
      assert {:ok, read} = Sheetshow.read_cells("Costs!A1:B1", workbook(url))

      assert Enum.map(read, & &1.value) == remembered |> Enum.take(2) |> Enum.map(& &1.value)
    end
  end
end
