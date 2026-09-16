defmodule Sheetshow.XlsxTest do
  use ExUnit.Case, async: true

  alias Sheetshow.{Cell, CellError, Coord, Error, Memory, Xlsx}
  alias Sheetshow.Xlsx.Zip

  # Two writers that disagree about nearly everything a reader cares about:
  # openpyxl puts text in the cell and ships no string table, xlsxwriter shares
  # its strings as Excel does; one writes relationship targets absolute, the
  # other relative. `dev/xlsx_fixtures.py` rebuilds both.
  @writers ["openpyxl", "xlsxwriter"]

  defp fixture(name), do: File.read!("test/fixtures/#{name}.xlsx")

  defp package(name) do
    {:ok, package} = Xlsx.open(fixture(name))
    package
  end

  defp costs(name) do
    {:ok, sheet} = Xlsx.sheet(package(name), "Costs")
    Map.new(sheet.cells, &{Coord.to_a1(%{&1.coord | sheet: nil}), &1})
  end

  describe "what both writers agree on" do
    for writer <- @writers do
      test "#{writer}: the sheets" do
        assert Xlsx.titles(package(unquote(writer))) == ["Costs", "log"]
      end

      test "#{writer}: strings, numbers and booleans" do
        cells = costs(unquote(writer))

        assert cells["A1"].value == "Item"
        assert cells["B2"].value == 1000
        assert cells["A3"].value == true
      end

      test "#{writer}: a whole number reads back whole, not as a float" do
        assert costs(unquote(writer))["B2"].value === 1000
      end

      test "#{writer}: a date, a datetime and a time, told apart by their number formats" do
        cells = costs(unquote(writer))

        assert cells["C2"].value == ~D[2026-09-13]
        assert cells["C3"].value == ~N[2026-09-13 08:30:00]
      end

      test "#{writer}: a formula is the formula, not what it worked out to" do
        assert costs(unquote(writer))["B4"].value == {:formula, "=B2*2"}
      end

      test "#{writer}: a bold, sized, coloured font" do
        assert costs(unquote(writer))["A1"].style == %{
                 bold: true,
                 font_size: 13,
                 font_family: "Calibri",
                 color: "#1155CC"
               }
      end

      test "#{writer}: a fill becomes a background" do
        assert costs(unquote(writer))["B1"].style == %{background: "#FFF2CC"}
      end

      test "#{writer}: an alignment" do
        assert costs(unquote(writer))["C1"].style == %{
                 horizontal: :center,
                 vertical: :top,
                 wrap: :wrap
               }
      end

      test "#{writer}: a plain cell has a plain style, the default font being no style at all" do
        assert costs(unquote(writer))["B2"].style == %{}
      end

      test "#{writer}: a number format is kept as the pattern it is" do
        assert costs(unquote(writer))["B3"].style[:number_format] == "#,##0.00"
        assert costs(unquote(writer))["B3"].value == 12.5
      end

      test "#{writer}: a styled cell remembers the index it came from" do
        cells = costs(unquote(writer))

        assert is_integer(cells["A1"].meta.style_id)
        assert cells["A1"].meta.style_id > 0
      end

      test "#{writer}: a plain cell says nothing, index 0 being the default" do
        refute Map.has_key?(costs(unquote(writer))["B2"].meta, :style_id)
      end

      test "#{writer}: a column width and a row height, in pixels" do
        {:ok, sheet} = Xlsx.sheet(package(unquote(writer)), "Costs")

        assert map_size(sheet.col_widths) == 1
        assert sheet.col_widths[0] > 100
        assert sheet.row_heights == %{1 => 40}
      end

      test "#{writer}: the empty second sheet is empty rather than missing" do
        {:ok, sheet} = Xlsx.sheet(package(unquote(writer)), "log")
        assert sheet.cells == []
      end

      test "#{writer}: decode gives a Memory the rest of the library can use" do
        {:ok, memory} = Xlsx.decode(fixture(unquote(writer)))

        assert Memory.titles(memory) == ["Costs", "log"]
        assert [%Cell{value: "Item"}] = Memory.read!("Costs!A1", memory)
        assert Memory.dimensions!("Costs", memory).row_heights == %{1 => 40}
      end
    end
  end

  describe "where the writers differ" do
    test "an inline string and a shared string read the same" do
      assert costs("openpyxl")["A2"].value == "Rent"
      assert costs("xlsxwriter")["A2"].value == "Rent"
    end

    test "a shared string used twice is the same string both times" do
      cells = costs("xlsxwriter")
      assert cells["A2"].value == "Rent"
      assert cells["C4"].value == "Rent"
    end

    test "a cached formula result is kept when the writer wrote one" do
      assert costs("xlsxwriter")["B4"].meta.effective == 2000
    end

    test "and is simply absent when it did not" do
      refute Map.has_key?(costs("openpyxl")["B4"].meta, :effective)
    end

    test "escaped text comes back unescaped" do
      assert costs("openpyxl")["C4"].value == "a string with <angle> & ampersand"
    end

    test "a time-only number format gives a Time" do
      assert costs("openpyxl")["A4"].value == ~T[14:45:00]
    end
  end

  describe "opening" do
    test "reads no worksheet: a package with a damaged sheet still opens" do
      {:ok, entries} = Zip.read(fixture("xlsxwriter"))
      damaged = entries |> Zip.put("xl/worksheets/sheet1.xml", "<not xml") |> Zip.write()
      {:ok, damaged} = damaged

      assert {:ok, package} = Xlsx.open(damaged)
      assert Xlsx.titles(package) == ["Costs", "log"]
      assert {:error, %Error{reason: :invalid_xlsx}} = Xlsx.sheet(package, "Costs")
      assert {:ok, _} = Xlsx.sheet(package, "log")
    end

    test "a sheet the workbook does not list" do
      assert {:error, %Error{reason: :unknown_sheet} = error} =
               Xlsx.sheet(package("openpyxl"), "nope")

      assert error.details.sheets == ["Costs", "log"]
    end

    test "something that is not a zip" do
      assert {:error, %Error{reason: :invalid_zip}} = Xlsx.open("not a workbook")
    end

    test "a zip that is not a workbook" do
      {:ok, bin} = Zip.write(Zip.put([], "hello.txt", "hi"))

      assert {:error, %Error{reason: :unknown_entry} = error} = Xlsx.open(bin)
      assert error.details.entry == "_rels/.rels"
    end

    test "decode! raises rather than returning" do
      assert_raise Error, fn -> Xlsx.decode!("not a workbook") end
    end
  end

  # Cases neither writer produces, assembled by replacing one part of a real
  # package so everything around them is still what a real writer wrote.
  describe "cells the fixtures do not have" do
    defp with_sheet(inner, opts \\ []) do
      {:ok, entries} = Zip.read(fixture("xlsxwriter"))
      {:ok, xml} = Zip.fetch(entries, "xl/worksheets/sheet1.xml")
      {head, tail} = Sheetshow.Xlsx.Sheet.split(xml)

      body =
        case Keyword.get(opts, :raw) do
          nil -> head <> "<sheetData>" <> inner <> "</sheetData>" <> tail
          raw -> head <> raw <> tail
        end

      {:ok, bin} = entries |> Zip.put("xl/worksheets/sheet1.xml", body) |> Zip.write()
      {:ok, package} = Xlsx.open(bin)
      {:ok, sheet} = Xlsx.sheet(package, "Costs")
      Map.new(sheet.cells, &{Coord.to_a1(%{&1.coord | sheet: nil}), &1})
    end

    test "an empty sheetData" do
      assert with_sheet("", raw: "<sheetData/>") == %{}
    end

    test "an error cell becomes a CellError, never a value" do
      cells = with_sheet(~s(<row r="1"><c r="A1" t="e"><f>1/0</f><v>#DIV/0!</v></c></row>))

      assert cells["A1"].value == {:formula, "=1/0"}
      assert cells["A1"].meta.effective == %CellError{type: :divide_by_zero}
    end

    test "an error type nobody has heard of stays the text it was" do
      cells = with_sheet(~s(<row r="1"><c r="A1" t="e"><v>#SPILL!</v></c></row>))
      assert cells["A1"].meta == %{}
      assert cells["A1"].value == %CellError{type: "#SPILL!"}
    end

    test "a formula result that is a string" do
      cells = with_sheet(~s(<row r="1"><c r="A1" t="str"><f>A2</f><v>hello</v></c></row>))

      assert cells["A1"].value == {:formula, "=A2"}
      assert cells["A1"].meta.effective == "hello"
    end

    test "a cell with no reference takes the next column along" do
      cells = with_sheet(~s(<row r="3"><c t="n"><v>1</v></c><c t="n"><v>2</v></c></row>))

      assert cells["A3"].value == 1
      assert cells["B3"].value == 2
    end

    test "a row with no reference follows the one above it" do
      cells = with_sheet(~s(<row><c r="A1"><v>1</v></c></row><row><c><v>2</v></c></row>))

      assert cells["A1"].value == 1
      assert cells["A2"].value == 2
    end

    test "a cell with nothing in it is not a cell" do
      cells = with_sheet(~s(<row r="1"><c r="A1"/><c r="B1"><v>1</v></c></row>))

      refute Map.has_key?(cells, "A1")
      assert cells["B1"].value == 1
    end

    test "a cell that is only a style is still a cell" do
      cells = with_sheet(~s(<row r="1"><c r="A1" s="2"/></row>))

      assert cells["A1"].value == nil
      assert cells["A1"].style == %{background: "#FFF2CC"}
    end

    test "a style index the workbook does not have is plain rather than an error" do
      cells = with_sheet(~s(<row r="1"><c r="A1" s="999"><v>1</v></c></row>))

      assert cells["A1"].value == 1
      assert cells["A1"].style == %{}
    end

    test "a shared string index past the end of the table loses the cell, not the read" do
      cells = with_sheet(~s(<row r="1"><c r="A1" t="s"><v>9999</v></c></row>))
      assert cells["A1"].value == nil
    end

    test "a column beyond Z" do
      cells = with_sheet(~s(<row r="1"><c r="AB1"><v>1</v></c></row>))
      assert cells["AB1"].value == 1
    end
  end
end
