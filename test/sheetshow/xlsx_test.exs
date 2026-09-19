defmodule Sheetshow.XlsxTest do
  use ExUnit.Case, async: true

  alias Sheetshow.{Cell, CellError, Coord, Error, Memory, Xlsx}
  alias Sheetshow.Xlsx.{Strings, Zip}

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
      assert cells["A1"].meta.effective == %CellError{type: "#SPILL!"}
    end

    test "an error cell with no formula keeps its error in meta, never as a value" do
      # An error is what a spreadsheet worked out, never something typed, so it
      # goes where a formula's error goes and never becomes a cell value. That is
      # also what keeps a later write to the sheet from tripping over it.
      cells = with_sheet(~s(<row r="1"><c r="A1" t="e"><v>#DIV/0!</v></c></row>))
      assert cells["A1"].value == nil
      assert cells["A1"].meta.effective == %CellError{type: :divide_by_zero}
    end

    test "a formula result that is a string" do
      cells = with_sheet(~s(<row r="1"><c r="A1" t="str"><f>A2</f><v>hello</v></c></row>))

      assert cells["A1"].value == {:formula, "=A2"}
      assert cells["A1"].meta.effective == "hello"
    end

    test "an ISO-date cell reads as a date, whatever its number format" do
      cells = with_sheet(~s(<row r="1"><c r="A1" t="d"><v>2026-09-18T12:30:00</v></c></row>))
      assert cells["A1"].value == ~N[2026-09-18 12:30:00]
    end

    test "an ISO date with no time reads as a Date" do
      cells = with_sheet(~s(<row r="1"><c r="A1" t="d"><v>2026-09-18</v></c></row>))
      assert cells["A1"].value == ~D[2026-09-18]
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

    test "a rich inline string reads as one string" do
      cells =
        with_sheet(
          ~s(<row r="1"><c r="A1" t="inlineStr"><is><r><rPr><b/></rPr><t>Bold</t></r>) <>
            ~s(<r><t xml:space="preserve"> plain</t></r></is></c></row>)
        )

      assert cells["A1"].value == "Bold plain"
    end

    test "an empty formula element is no formula at all" do
      cells = with_sheet(~s(<row r="1"><c r="A1"><f/><v>3</v></c></row>))
      assert cells["A1"].value == 3
    end
  end

  # Excel writes a column of filled-down formulas once: the first cell carries
  # the text and a `ref`, the rest carry only `t="shared"` and the `si` that
  # says which one. Before M8.12 those cells read as `{:formula, "="}` and were
  # written back as `<f></f>`, which took the formulas out of the file.
  describe "shared formulas" do
    test "the cells below the first read as its formula moved down to them" do
      cells =
        with_sheet(
          ~s(<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f t="shared" ref="B1:B3" si="0">A1*2</f><v>2</v></c></row>) <>
            ~s(<row r="2"><c r="A2"><v>2</v></c><c r="B2"><f t="shared" si="0"/><v>4</v></c></row>) <>
            ~s(<row r="3"><c r="A3"><v>3</v></c><c r="B3"><f t="shared" si="0"/><v>6</v></c></row>)
        )

      assert cells["B1"].value == {:formula, "=A1*2"}
      assert cells["B2"].value == {:formula, "=A2*2"}
      assert cells["B3"].value == {:formula, "=A3*2"}
      assert cells["B3"].meta.effective == 6
    end

    test "and across, when the range runs that way" do
      cells =
        with_sheet(
          ~s(<row r="2"><c r="B2"><f t="shared" ref="B2:D2" si="3">$A2+B1</f><v>1</v></c>) <>
            ~s(<c r="C2"><f t="shared" si="3"/><v>2</v></c>) <>
            ~s(<c r="D2"><f t="shared" si="3"/><v>3</v></c></row>)
        )

      assert cells["C2"].value == {:formula, "=$A2+C1"}
      assert cells["D2"].value == {:formula, "=$A2+D1"}
    end

    test "two groups on one sheet keep to their own si" do
      cells =
        with_sheet(
          ~s(<row r="1"><c r="A1"><f t="shared" ref="A1:A2" si="0">B1</f></c>) <>
            ~s(<c r="C1"><f t="shared" ref="C1:C2" si="1">D1*2</f></c></row>) <>
            ~s(<row r="2"><c r="A2"><f t="shared" si="0"/></c><c r="C2"><f t="shared" si="1"/></c></row>)
        )

      assert cells["A2"].value == {:formula, "=B2"}
      assert cells["C2"].value == {:formula, "=D2*2"}
    end

    test "a pointer to a formula the part never wrote keeps its cached value" do
      cells = with_sheet(~s(<row r="2"><c r="B2"><f t="shared" si="9"/><v>4</v></c></row>))
      assert cells["B2"].value == 4
      assert cells["B2"].meta == %{}
    end
  end

  # A writer may spell the worksheet's elements with a namespace prefix. The
  # SAX events name elements without one, so such a sheet reads; but the
  # writer here works on the part's text and looks for `<sheetData`, so it is
  # marked read-only rather than written back with two sheetData elements.
  describe "a worksheet with a namespace prefix" do
    setup do
      prefixed =
        ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
          ~s(<x:worksheet xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main">) <>
          ~s(<x:sheetData><x:row r="1"><x:c r="A1"><x:v>7</x:v></x:c></x:row></x:sheetData></x:worksheet>)

      {:ok, entries} = Zip.read(fixture("xlsxwriter"))
      {:ok, bin} = entries |> Zip.put("xl/worksheets/sheet1.xml", prefixed) |> Zip.write()
      {:ok, package} = Xlsx.open(bin)
      %{package: package}
    end

    test "reads", %{package: package} do
      {:ok, sheet} = Xlsx.sheet(package, "Costs")
      assert [%Cell{value: 7}] = sheet.cells
      refute sheet.writable
    end

    test "but is refused a write, before anything is encoded", %{package: package} do
      {:ok, sheet} = Xlsx.sheet(package, "Costs")

      assert {:error, %Error{reason: :unsupported} = error} =
               Xlsx.put_sheet(package, "Costs", sheet)

      assert error.message =~ "namespace prefix"
    end

    test "an ordinary worksheet is writable", %{package: package} do
      {:ok, sheet} = Xlsx.sheet(package, "log")
      assert sheet.writable
    end
  end

  describe "0.1.2 regressions" do
    test "a float too small for fixed decimals round-trips instead of becoming zero" do
      package = Xlsx.new()
      {:ok, sheet} = Xlsx.sheet(package, "Sheet1")

      {:ok, package} =
        Xlsx.put_sheet(package, "Sheet1", %{sheet | cells: [Cell.new("Sheet1!A1", 1.0e-20)]})

      {:ok, bytes} = Xlsx.encode(package)
      {:ok, memory} = Xlsx.decode(bytes)

      assert Sheetshow.to_rows(Memory.read!("Sheet1", memory)) == [[1.0e-20]]
    end

    test "an elapsed duration keeps its days: it reads as a number, not a Time" do
      # duration.xlsx holds 36 hours (serial 1.5) formatted [hh]:mm:ss. Read as a
      # Time it would come back 0.5, the days thrown away.
      {:ok, memory} = Xlsx.decode(File.read!("test/fixtures/duration.xlsx"))
      assert Sheetshow.to_rows(Memory.read!("Data", memory)) == [[1.5]]
    end

    test "an error cell does not crash a write to its sheet" do
      package = Xlsx.new()

      xml =
        ~s(<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">) <>
          ~s(<sheetData><row r="1"><c r="A1" t="e"><v>#DIV/0!</v></c></row></sheetData></worksheet>)

      {:ok, bytes} = package.entries |> Zip.put("xl/worksheets/sheet1.xml", xml) |> Zip.write()
      {:ok, package} = Xlsx.open(bytes)
      {:ok, sheet} = Xlsx.sheet(package, "Sheet1")

      edited = %{sheet | cells: sheet.cells ++ [Cell.new("Sheet1!C10", "edit")]}
      assert {:ok, package} = Xlsx.put_sheet(package, "Sheet1", edited)
      assert {:ok, _bytes} = Xlsx.encode(package)
    end

    test "a namespace-prefixed shared string table accepts a new string" do
      package = Xlsx.new()

      strings =
        ~s(<x:sst xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main">) <>
          ~s(<x:si><x:t>old</x:t></x:si></x:sst>)

      {:ok, bytes} = package.entries |> Zip.put("xl/sharedStrings.xml", strings) |> Zip.write()
      {:ok, package} = Xlsx.open(bytes)
      {:ok, sheet} = Xlsx.sheet(package, "Sheet1")

      {:ok, package} =
        Xlsx.put_sheet(package, "Sheet1", %{sheet | cells: [Cell.new("Sheet1!A1", "new")]})

      {:ok, bytes} = Xlsx.encode(package)
      {:ok, memory} = Xlsx.decode(bytes)

      assert Sheetshow.to_rows(Memory.read!("Sheet1", memory)) == [["new"]]
    end

    test "removing calcChain removes its part, relationship and content type together" do
      package = Xlsx.new()
      {:ok, rels} = Zip.fetch(package.entries, "xl/_rels/workbook.xml.rels")

      rel =
        ~s(<Relationship Id="rId99" ) <>
          ~s(Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/calcChain" ) <>
          ~s(Target="calcChain.xml"/>)

      {:ok, types} = Zip.fetch(package.entries, "[Content_Types].xml")

      override =
        ~s(<Override PartName="/xl/calcChain.xml" ) <>
          ~s(ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml"/>)

      entries =
        package.entries
        |> Zip.put(
          "xl/_rels/workbook.xml.rels",
          String.replace(rels, "</Relationships>", rel <> "</Relationships>")
        )
        |> Zip.put(
          "[Content_Types].xml",
          String.replace(types, "</Types>", override <> "</Types>")
        )
        |> Zip.put(
          "xl/calcChain.xml",
          ~s(<calcChain xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"/>)
        )

      {:ok, bytes} = Xlsx.encode(%{package | entries: entries})
      {:ok, after_entries} = Zip.read(bytes)
      {:ok, after_rels} = Zip.fetch(after_entries, "xl/_rels/workbook.xml.rels")
      {:ok, after_types} = Zip.fetch(after_entries, "[Content_Types].xml")

      refute after_rels =~ "calcChain"
      refute after_types =~ "calcChain"
      assert {:error, _} = Zip.fetch(after_entries, "xl/calcChain.xml")
    end
  end

  describe "0.1.3 regressions" do
    test "a built-in elapsed format (46) keeps its days: it reads as a number" do
      # duration_builtin.xlsx uses built-in format 46 ([h]:mm:ss) with no <numFmt>;
      # read as a Time it would come back 12:00 with the days gone.
      {:ok, memory} = Xlsx.decode(File.read!("test/fixtures/duration_builtin.xlsx"))
      assert Sheetshow.to_rows(Memory.read!("Data", memory)) == [[1.5]]
    end

    test "a bare ISO time reads as a Time, not nil" do
      {:ok, memory} = Xlsx.decode(File.read!("test/fixtures/iso_time.xlsx"))
      assert Sheetshow.to_rows(Memory.read!("Data", memory)) == [[~T[12:30:00]]]
    end

    test "removing calcChain also removes a namespace-prefixed relationship and override" do
      package = Xlsx.new()
      {:ok, rels} = Zip.fetch(package.entries, "xl/_rels/workbook.xml.rels")
      {:ok, types} = Zip.fetch(package.entries, "[Content_Types].xml")

      rel =
        ~s(<r:Relationship Id='rId99' ) <>
          ~s(Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/calcChain" ) <>
          ~s(Target="calcChain.xml"/>)

      override =
        ~s(<c:Override PartName='/xl/calcChain.xml' ) <>
          ~s(ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml"/>)

      entries =
        package.entries
        |> Zip.put(
          "xl/_rels/workbook.xml.rels",
          String.replace(rels, "</Relationships>", rel <> "</Relationships>")
        )
        |> Zip.put(
          "[Content_Types].xml",
          String.replace(types, "</Types>", override <> "</Types>")
        )
        |> Zip.put(
          "xl/calcChain.xml",
          ~s(<calcChain xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"/>)
        )

      {:ok, bytes} = Xlsx.encode(%{package | entries: entries})
      {:ok, after_entries} = Zip.read(bytes)
      {:ok, after_rels} = Zip.fetch(after_entries, "xl/_rels/workbook.xml.rels")
      {:ok, after_types} = Zip.fetch(after_entries, "[Content_Types].xml")

      refute after_rels =~ "calcChain"
      refute after_types =~ "calcChain"
      assert {:error, _} = Zip.fetch(after_entries, "xl/calcChain.xml")
    end

    test "a namespace-prefixed styles part refuses a write that adds a style" do
      # A styles.xml the parser reads but the writer cannot splice a new <xf> into
      # without prefixing it and every child; adding a style is refused rather than
      # written with an index the file cannot resolve.
      prefixed =
        ~s(<?xml version="1.0"?>) <>
          ~s(<x:styleSheet xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main">) <>
          ~s(<x:fonts count="1"><x:font><x:sz val="11"/><x:name val="Calibri"/></x:font></x:fonts>) <>
          ~s(<x:fills count="1"><x:fill><x:patternFill patternType="none"/></x:fill></x:fills>) <>
          ~s(<x:cellXfs count="1"><x:xf numFmtId="0" fontId="0" fillId="0"/></x:cellXfs>) <>
          ~s(</x:styleSheet>)

      {:ok, entries} = Zip.read(fixture("xlsxwriter"))
      {:ok, bytes} = entries |> Zip.put("xl/styles.xml", prefixed) |> Zip.write()
      {:ok, package} = Xlsx.open(bytes)
      {:ok, sheet} = Xlsx.sheet(package, "log")

      bold = %{sheet | cells: [Cell.new("log!A1", "hi", %{bold: true})]}
      {:ok, package} = Xlsx.put_sheet(package, "log", bold)

      assert {:error, %Error{reason: :unsupported} = error} = Xlsx.encode(package)
      assert error.message =~ "namespace prefix"
    end

    test "deleting the only sheet is refused rather than left unreadable" do
      {:ok, package} = Xlsx.delete_sheet(Xlsx.new(), "Sheet1")
      assert {:error, %Error{reason: :invalid_xlsx}} = Xlsx.encode(package)
    end

    test "a standalone error cell survives an unrelated edit" do
      xml =
        ~s(<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">) <>
          ~s(<sheetData><row r="1"><c r="A1" t="e"><v>#DIV/0!</v></c></row></sheetData></worksheet>)

      {:ok, bytes} = Xlsx.new().entries |> Zip.put("xl/worksheets/sheet1.xml", xml) |> Zip.write()
      {:ok, package} = Xlsx.open(bytes)
      {:ok, sheet} = Xlsx.sheet(package, "Sheet1")

      edited = %{sheet | cells: sheet.cells ++ [Cell.new("Sheet1!C10", "edit")]}
      {:ok, package} = Xlsx.put_sheet(package, "Sheet1", edited)
      {:ok, bytes} = Xlsx.encode(package)

      {:ok, reopened} = Xlsx.open(bytes)
      {:ok, sheet} = Xlsx.sheet(reopened, "Sheet1")
      a1 = Enum.find(sheet.cells, &(Sheetshow.Coord.to_a1(%{&1.coord | sheet: nil}) == "A1"))

      assert a1.meta.effective == %CellError{type: :divide_by_zero}
    end
  end

  describe "0.1.4 regressions" do
    test "adding a sheet does not redirect an existing one when relationship ids are single-quoted" do
      # free_rid scanned only Id="rId..."; a file that quotes with ' read fine but
      # then allocated rId1 over one already taken, so the new sheet and the old one
      # shared an id and the old tab resolved to the new, empty part.
      {:ok, entries} = Zip.read(fixture("xlsxwriter"))
      {:ok, rels} = Zip.fetch(entries, "xl/_rels/workbook.xml.rels")
      single = Regex.replace(~r/Id="([^"]*)"/, rels, "Id='\\1'")
      {:ok, bytes} = entries |> Zip.put("xl/_rels/workbook.xml.rels", single) |> Zip.write()

      {:ok, package} = Xlsx.open(bytes)
      {:ok, package} = Xlsx.add_sheet(package, "Fresh")
      {:ok, out} = Xlsx.encode(package)
      {:ok, memory} = Xlsx.decode(out)

      assert Sheetshow.to_rows(Memory.read!("Costs", memory)) |> hd() |> hd() == "Item"
      assert Sheetshow.to_rows(Memory.read!("Fresh", memory)) == []
    end

    test "removing calcChain handles whitespace around = and a non-self-closing declaration" do
      package = Xlsx.new()
      {:ok, rels} = Zip.fetch(package.entries, "xl/_rels/workbook.xml.rels")
      {:ok, types} = Zip.fetch(package.entries, "[Content_Types].xml")

      rel =
        ~s(<Relationship Id = "rId99" ) <>
          ~s(Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/calcChain" ) <>
          ~s(Target="calcChain.xml"></Relationship>)

      override =
        ~s(<Override PartName = "/xl/calcChain.xml" ) <>
          ~s(ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml"></Override>)

      entries =
        package.entries
        |> Zip.put(
          "xl/_rels/workbook.xml.rels",
          String.replace(rels, "</Relationships>", rel <> "</Relationships>")
        )
        |> Zip.put(
          "[Content_Types].xml",
          String.replace(types, "</Types>", override <> "</Types>")
        )
        |> Zip.put(
          "xl/calcChain.xml",
          ~s(<calcChain xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"/>)
        )

      {:ok, bytes} = Xlsx.encode(%{package | entries: entries})
      {:ok, after_entries} = Zip.read(bytes)
      {:ok, after_rels} = Zip.fetch(after_entries, "xl/_rels/workbook.xml.rels")
      {:ok, after_types} = Zip.fetch(after_entries, "[Content_Types].xml")

      refute after_rels =~ "calcChain"
      refute after_types =~ "calcChain"
      assert {:error, _} = Zip.fetch(after_entries, "xl/calcChain.xml")
    end

    test "a styles part whose lists are prefixed but whose root is not is read-only too" do
      # Checking the root <styleSheet> alone missed a file whose lists carry the
      # prefix; splicing an unprefixed <xf> into a prefixed list leaves an index the
      # file cannot resolve, so such a write is refused.
      prefixed =
        ~s(<?xml version="1.0"?>) <>
          ~s(<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ) <>
          ~s(xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main">) <>
          ~s(<x:fonts count="1"><x:font><x:sz val="11"/><x:name val="Calibri"/></x:font></x:fonts>) <>
          ~s(<x:fills count="1"><x:fill><x:patternFill patternType="none"/></x:fill></x:fills>) <>
          ~s(<x:cellXfs count="1"><x:xf numFmtId="0" fontId="0" fillId="0"/></x:cellXfs>) <>
          ~s(</styleSheet>)

      {:ok, entries} = Zip.read(fixture("xlsxwriter"))
      {:ok, bytes} = entries |> Zip.put("xl/styles.xml", prefixed) |> Zip.write()
      {:ok, package} = Xlsx.open(bytes)
      {:ok, sheet} = Xlsx.sheet(package, "log")

      bold = %{sheet | cells: [Cell.new("log!A1", "hi", %{bold: true})]}
      {:ok, package} = Xlsx.put_sheet(package, "log", bold)

      assert {:error, %Error{reason: :unsupported}} = Xlsx.encode(package)
    end

    test "a shared string that looks like an escape survives a write and a read" do
      strings = Strings.shared()
      {0, strings} = Strings.put(strings, "_x0041_")
      {1, strings} = Strings.put(strings, "line\rbreak")

      {:ok, back} = strings |> Strings.render() |> IO.iodata_to_binary() |> Strings.parse()

      assert Strings.fetch(back, 0) == "_x0041_"
      assert Strings.fetch(back, 1) == "line\rbreak"
    end
  end

  describe "0.1.5 regressions" do
    test "removing calcChain handles a declaration with whitespace between its tags" do
      # An expanded declaration can carry whitespace between the tags
      # (`<Relationship ...>\n</Relationship>`); a pattern that assumed the close
      # tag followed immediately left it, and its override, pointing at a part the
      # encode had already deleted.
      package = Xlsx.new()
      {:ok, rels} = Zip.fetch(package.entries, "xl/_rels/workbook.xml.rels")
      {:ok, types} = Zip.fetch(package.entries, "[Content_Types].xml")

      rel =
        ~s(<Relationship Id="rId99" ) <>
          ~s(Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/calcChain" ) <>
          ~s(Target="calcChain.xml">\n  </Relationship>)

      override =
        ~s(<Override PartName="/xl/calcChain.xml" ) <>
          ~s(ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml">\n  </Override>)

      entries =
        package.entries
        |> Zip.put(
          "xl/_rels/workbook.xml.rels",
          String.replace(rels, "</Relationships>", rel <> "</Relationships>")
        )
        |> Zip.put(
          "[Content_Types].xml",
          String.replace(types, "</Types>", override <> "</Types>")
        )
        |> Zip.put(
          "xl/calcChain.xml",
          ~s(<calcChain xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"/>)
        )

      {:ok, bytes} = Xlsx.encode(%{package | entries: entries})
      {:ok, after_entries} = Zip.read(bytes)
      {:ok, after_rels} = Zip.fetch(after_entries, "xl/_rels/workbook.xml.rels")
      {:ok, after_types} = Zip.fetch(after_entries, "[Content_Types].xml")

      refute after_rels =~ "calcChain"
      refute after_types =~ "calcChain"
      assert {:error, _} = Zip.fetch(after_entries, "xl/calcChain.xml")
    end

    test "a shared string with an escaped surrogate pair reads as the character" do
      # The decoder converted each _xHHHH_ to a code point on its own and raised on
      # the high surrogate, so the whole read came back :invalid_xlsx.
      xml =
        ~s(<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1" uniqueCount="1">) <>
          ~s(<si><t>hi _xD83D__xDE00_</t></si></sst>)

      assert {:ok, strings} = Strings.parse(xml)
      assert Strings.fetch(strings, 0) == "hi 😀"
    end
  end
end
