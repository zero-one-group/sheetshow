defmodule Sheetshow.Xlsx.WriteTest do
  use ExUnit.Case, async: true

  alias Sheetshow.{Cell, Coord, Error, Xlsx}
  alias Sheetshow.Xlsx.Zip

  @writers ["openpyxl", "xlsxwriter"]

  defp fixture(name), do: File.read!("test/fixtures/#{name}.xlsx")

  defp opened(name) do
    {:ok, package} = Xlsx.open(fixture(name))
    package
  end

  defp costs(package) do
    {:ok, sheet} = Xlsx.sheet(package, "Costs")
    sheet
  end

  defp by_ref(sheet), do: Map.new(sheet.cells, &{Coord.to_a1(%{&1.coord | sheet: nil}), &1})

  # Write a sheet back, encode, and open what came out.
  defp rewritten(package, title, sheet) do
    {:ok, package} = Xlsx.put_sheet(package, title, sheet)
    {:ok, bin} = Xlsx.encode(package)
    {:ok, reopened} = Xlsx.open(bin)
    {bin, reopened}
  end

  defp part(bin, name) do
    {:ok, entries} = Zip.read(bin)
    {:ok, xml} = Zip.fetch(entries, name)
    xml
  end

  describe "a workbook read and written back" do
    for writer <- @writers do
      test "#{writer}: every cell comes back as it went down" do
        package = opened(unquote(writer))
        sheet = costs(package)
        {_bin, reopened} = rewritten(package, "Costs", sheet)

        before = by_ref(sheet)
        after_ = by_ref(costs(reopened))

        assert Map.keys(after_) |> Enum.sort() == Map.keys(before) |> Enum.sort()

        for {ref, cell} <- before do
          assert after_[ref].value == cell.value, "#{ref} changed value"
          assert after_[ref].style == cell.style, "#{ref} changed style"
        end
      end

      test "#{writer}: a cell nobody touched keeps the very style index it had" do
        package = opened(unquote(writer))
        sheet = costs(package)
        {bin, _} = rewritten(package, "Costs", sheet)

        before = by_ref(sheet)
        after_ = by_ref(costs(elem(Xlsx.open(bin), 1)))

        for ref <- ~w(A1 B1 C1 C2 B3) do
          assert Map.get(after_[ref].meta, :style_id) == Map.get(before[ref].meta, :style_id),
                 "#{ref} was given a new style rather than keeping its own"
        end
      end

      test "#{writer}: column widths and row heights survive the trip" do
        package = opened(unquote(writer))
        sheet = costs(package)
        {_bin, reopened} = rewritten(package, "Costs", sheet)
        back = costs(reopened)

        # The width a file stores is in characters, and the conversion assumes a
        # digit seven pixels wide, so a pixel of drift is the medium, not a bug.
        assert map_size(back.col_widths) == map_size(sheet.col_widths)
        assert_in_delta back.col_widths[0], sheet.col_widths[0], 1
        assert back.row_heights == sheet.row_heights
      end

      test "#{writer}: an edited value, and the cells beside it left alone" do
        package = opened(unquote(writer))
        sheet = costs(package)

        cells =
          Enum.map(sheet.cells, fn cell ->
            if cell.coord.row == 1 and cell.coord.col == 1, do: %{cell | value: 2500}, else: cell
          end)

        {_bin, reopened} = rewritten(package, "Costs", %{sheet | cells: cells})
        after_ = by_ref(costs(reopened))

        assert after_["B2"].value == 2500
        assert after_["A2"].value == "Rent"
        assert after_["C2"].value == ~D[2026-09-13]
      end

      test "#{writer}: a new cell with a style the workbook has never seen" do
        package = opened(unquote(writer))
        sheet = costs(package)

        added =
          Cell.new(Coord.new(9, 0, "Costs"), "added", %{
            bold: true,
            background: "#DDEEFF",
            horizontal: :right
          })

        {_bin, reopened} = rewritten(package, "Costs", %{sheet | cells: sheet.cells ++ [added]})
        after_ = by_ref(costs(reopened))

        assert after_["A10"].value == "added"
        assert after_["A10"].style == %{bold: true, background: "#DDEEFF", horizontal: :right}
      end

      test "#{writer}: a date written without a format still reads back as a date" do
        package = opened(unquote(writer))
        sheet = costs(package)
        added = Cell.new(Coord.new(9, 1, "Costs"), ~D[2027-01-02])

        {_bin, reopened} = rewritten(package, "Costs", %{sheet | cells: sheet.cells ++ [added]})

        assert by_ref(costs(reopened))["B10"].value == ~D[2027-01-02]
      end

      test "#{writer}: text with characters XML minds, and text it has never met" do
        package = opened(unquote(writer))
        sheet = costs(package)

        added = [
          Cell.new(Coord.new(9, 0, "Costs"), ~s(a & b < c > d "quoted")),
          Cell.new(Coord.new(9, 1, "Costs"), "東京 — Tōkyō")
        ]

        {_bin, reopened} = rewritten(package, "Costs", %{sheet | cells: sheet.cells ++ added})
        after_ = by_ref(costs(reopened))

        assert after_["A10"].value == ~s(a & b < c > d "quoted")
        assert after_["B10"].value == "東京 — Tōkyō"
      end

      test "#{writer}: calcChain.xml is dropped, because it names cells by position" do
        package = opened(unquote(writer))
        {:ok, package} = Xlsx.put_sheet(package, "Costs", costs(package))
        {:ok, bin} = Xlsx.encode(package)
        {:ok, entries} = Zip.read(bin)

        refute Enum.any?(Zip.names(entries), &String.ends_with?(&1, "calcChain.xml"))
      end
    end
  end

  describe "the tables only ever grow" do
    test "a string the workbook already shares keeps the index it had" do
      package = opened("xlsxwriter")
      sheet = costs(package)
      before = part(fixture("xlsxwriter"), "xl/sharedStrings.xml")

      # "Rent" is already in the table twice over.
      added = Cell.new(Coord.new(9, 0, "Costs"), "Rent")
      {bin, _} = rewritten(package, "Costs", %{sheet | cells: sheet.cells ++ [added]})

      assert part(bin, "xl/sharedStrings.xml") == before
    end

    test "a new string is appended, leaving every index before it alone" do
      package = opened("xlsxwriter")
      sheet = costs(package)
      added = Cell.new(Coord.new(9, 0, "Costs"), "brand new")
      {bin, reopened} = rewritten(package, "Costs", %{sheet | cells: sheet.cells ++ [added]})

      written = part(bin, "xl/sharedStrings.xml")

      assert written =~ "brand new"
      assert written =~ ~s(uniqueCount="5")
      # everything that was there is still there, in the order it was
      for string <- ~w(Item Cost When Rent), do: assert(written =~ string)
      assert by_ref(costs(reopened))["A10"].value == "brand new"
    end

    test "a workbook that shares no strings does not gain a table" do
      package = opened("openpyxl")
      sheet = costs(package)
      added = Cell.new(Coord.new(9, 0, "Costs"), "brand new")
      {bin, reopened} = rewritten(package, "Costs", %{sheet | cells: sheet.cells ++ [added]})

      {:ok, entries} = Zip.read(bin)
      refute Enum.any?(Zip.names(entries), &String.ends_with?(&1, "sharedStrings.xml"))
      assert part(bin, "xl/worksheets/sheet1.xml") =~ "inlineStr"
      assert by_ref(costs(reopened))["A10"].value == "brand new"
    end

    test "a new style is appended, leaving every cellXf before it alone" do
      package = opened("xlsxwriter")
      sheet = costs(package)
      before = part(fixture("xlsxwriter"), "xl/styles.xml")
      added = Cell.new(Coord.new(9, 0, "Costs"), "x", %{italic: true})
      {bin, _} = rewritten(package, "Costs", %{sheet | cells: sheet.cells ++ [added]})

      written = part(bin, "xl/styles.xml")

      assert written =~ "<i/>"
      # the original cellXfs are still there, in order, before ours
      {_, original_xfs} = :binary.match(before, "<cellXfs")
      assert original_xfs > 0

      assert String.contains?(
               written,
               extract(before, "cellXfs") |> String.trim_trailing("</cellXfs>")
             )
    end

    test "a style the workbook already has is reused rather than added again" do
      package = opened("xlsxwriter")
      sheet = costs(package)
      before = part(fixture("xlsxwriter"), "xl/styles.xml")

      # The same style A1 already wears.
      style = by_ref(sheet)["A1"].style
      added = Cell.new(Coord.new(9, 0, "Costs"), "x", style)
      {bin, _} = rewritten(package, "Costs", %{sheet | cells: sheet.cells ++ [added]})

      assert part(bin, "xl/styles.xml") == before
    end

    test "a number format the workbook already spells out is not spelled out twice" do
      package = opened("xlsxwriter")
      sheet = costs(package)
      added = Cell.new(Coord.new(9, 0, "Costs"), 1, %{number_format: "#,##0.00"})
      {bin, reopened} = rewritten(package, "Costs", %{sheet | cells: sheet.cells ++ [added]})

      written = part(bin, "xl/styles.xml")
      assert length(String.split(written, ~s(formatCode="#,##0.00"))) <= 2
      assert by_ref(costs(reopened))["A10"].style[:number_format] == "#,##0.00"
    end
  end

  # The string table is spliced, not rebuilt, because an <si> can say more than
  # its text and the cells pointing at it may be on sheets nobody touched.
  describe "the string table as it was" do
    defp with_strings(sst) do
      {:ok, entries} = Zip.read(fixture("xlsxwriter"))
      {:ok, bin} = entries |> Zip.put("xl/sharedStrings.xml", sst) |> Zip.write()
      {:ok, package} = Xlsx.open(bin)
      package
    end

    defp sst(inner, count) do
      ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
        ~s(<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ) <>
        ~s(count="#{count}" uniqueCount="#{count}">#{inner}</sst>)
    end

    test "a run of bold inside a string survives a new string being added" do
      rich =
        ~s(<si><r><rPr><b/></rPr><t>Bold</t></r><r><t xml:space="preserve"> plain</t></r></si>)

      package = with_strings(sst(rich <> "<si><t>x</t></si>", 2))
      sheet = costs(package)

      added = Cell.new(Coord.new(9, 0, "Costs"), "brand new")
      {bin, reopened} = rewritten(package, "Costs", %{sheet | cells: sheet.cells ++ [added]})
      written = part(bin, "xl/sharedStrings.xml")

      assert String.contains?(written, rich)
      assert written =~ ~s(count="3" uniqueCount="3")
      assert String.ends_with?(written, ~s(<si><t xml:space="preserve">brand new</t></si></sst>))
      assert by_ref(costs(reopened))["A10"].value == "brand new"
    end

    test "an empty table that was self-closed is opened up" do
      package =
        with_strings(
          ~s(<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="0" uniqueCount="0"/>)
        )

      sheet = costs(package)
      cells = [Cell.new(Coord.new(0, 0, "Costs"), "only")]
      {bin, reopened} = rewritten(package, "Costs", %{sheet | cells: cells})

      assert part(bin, "xl/sharedStrings.xml") =~
               ~s(count="1" uniqueCount="1"><si><t xml:space="preserve">only</t></si></sst>)

      assert by_ref(costs(reopened))["A1"].value == "only"
    end

    test "a string holding what a regex would read as a backreference" do
      package = opened("xlsxwriter")
      sheet = costs(package)
      added = Cell.new(Coord.new(9, 0, "Costs"), ~S(C:\1\0 and \g{1}))
      {_bin, reopened} = rewritten(package, "Costs", %{sheet | cells: sheet.cells ++ [added]})

      assert by_ref(costs(reopened))["A10"].value == ~S(C:\1\0 and \g{1})
    end
  end

  describe "what is beside the cells" do
    test "two neighbouring columns of different widths are two col elements" do
      package = opened("openpyxl")
      sheet = costs(package)
      widths = %{0 => 100, 1 => 100, 2 => 150}
      {bin, reopened} = rewritten(package, "Costs", %{sheet | col_widths: widths})

      cols = part(bin, "xl/worksheets/sheet1.xml")
      assert cols =~ ~s(<col min="1" max="2" )
      assert cols =~ ~s(<col min="3" max="3" )

      back = costs(reopened)
      assert_in_delta back.col_widths[1], 100, 1
      assert_in_delta back.col_widths[2], 150, 1
    end

    test "a sheet emptied of cells loses its dimension hint and its cols" do
      package = opened("openpyxl")
      sheet = costs(package)
      {bin, reopened} = rewritten(package, "Costs", %{sheet | cells: [], col_widths: %{}})

      xml = part(bin, "xl/worksheets/sheet1.xml")
      refute xml =~ "<dimension"
      refute xml =~ "<cols"
      assert xml =~ "<sheetData></sheetData>"
      assert costs(reopened).cells == []
    end

    test "vertical alignment, underline and strikethrough go down and come back" do
      package = opened("openpyxl")
      sheet = costs(package)
      style = %{vertical: :middle, horizontal: :center, underline: true, strikethrough: true}
      added = Cell.new(Coord.new(9, 0, "Costs"), "x", style)
      {_bin, reopened} = rewritten(package, "Costs", %{sheet | cells: sheet.cells ++ [added]})

      assert by_ref(costs(reopened))["A10"].style == style
    end
  end

  describe "passthrough" do
    setup do
      # A worksheet carrying every sibling of <sheetData> that a rewrite would
      # otherwise throw away, spliced into a package a real writer produced.
      siblings = """
      <autoFilter ref="A1:C4"/>\
      <mergeCells count="1"><mergeCell ref="E1:F1"/></mergeCells>\
      <conditionalFormatting sqref="B2:B4"><cfRule type="cellIs" priority="1" operator="greaterThan">\
      <formula>100</formula></cfRule></conditionalFormatting>\
      <dataValidations count="1"><dataValidation type="list" sqref="A2:A4">\
      <formula1>"yes,no"</formula1></dataValidation></dataValidations>\
      """

      {:ok, entries} = Zip.read(File.read!("test/fixtures/xlsxwriter.xlsx"))
      {:ok, xml} = Zip.fetch(entries, "xl/worksheets/sheet1.xml")
      {head, tail} = Sheetshow.Xlsx.Sheet.split(xml)

      head =
        String.replace(
          head,
          "<sheetViews>",
          ~s(<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" state="frozen"/></sheetView></sheetViews><ignore>),
          global: false
        )
        |> String.replace(
          "<ignore>" <> "<sheetView tabSelected=\"1\" workbookViewId=\"0\"/></sheetViews>",
          ""
        )

      body = head <> "<sheetData>" <> inner(xml) <> "</sheetData>" <> siblings <> tail
      {:ok, bin} = entries |> Zip.put("xl/worksheets/sheet1.xml", body) |> Zip.write()

      %{bin: bin}
    end

    defp inner(xml) do
      [_, rest] = :binary.split(xml, "<sheetData>")
      [inner, _] = :binary.split(rest, "</sheetData>")
      inner
    end

    test "every sibling of sheetData survives a rewrite", %{bin: bin} do
      {:ok, package} = Xlsx.open(bin)
      {:ok, sheet} = Xlsx.sheet(package, "Costs")
      {out, _} = rewritten(package, "Costs", sheet)

      written = part(out, "xl/worksheets/sheet1.xml")

      for what <- [
            "<autoFilter",
            "<mergeCells",
            "<conditionalFormatting",
            "<dataValidations",
            ~s(state="frozen"),
            "<pageMargins"
          ] do
        assert String.contains?(written, what), "#{what} was lost"
      end
    end

    test "and nothing else in the package is rewritten", %{bin: bin} do
      {:ok, package} = Xlsx.open(bin)
      {:ok, sheet} = Xlsx.sheet(package, "Costs")
      {out, _} = rewritten(package, "Costs", sheet)

      {:ok, before} = Zip.read(bin)
      {:ok, after_} = Zip.read(out)
      held = Map.new(before, &{&1.name, &1.data})

      for entry <- after_, entry.name != "xl/worksheets/sheet1.xml" do
        assert entry.data == held[entry.name], "#{entry.name} was rewritten"
      end
    end
  end

  describe "sheets" do
    test "one can be added, and written to" do
      package = opened("openpyxl")
      assert {:ok, package} = Xlsx.add_sheet(package, "fresh")
      assert Xlsx.titles(package) == ["Costs", "fresh", "log"]

      {:ok, sheet} = Xlsx.sheet(package, "fresh")
      assert sheet.cells == []

      cells = [Cell.new(Coord.new(0, 0, "fresh"), "hello")]
      {_bin, reopened} = rewritten(package, "fresh", %{sheet | cells: cells})

      assert Xlsx.titles(reopened) == ["Costs", "fresh", "log"]
      {:ok, back} = Xlsx.sheet(reopened, "fresh")
      assert [%Cell{value: "hello"}] = back.cells
    end

    test "one that is already there is refused" do
      assert {:error, %Error{reason: :duplicate_sheet}} =
               Xlsx.add_sheet(opened("openpyxl"), "log")
    end

    test "one can be taken away, and everything pointing at it goes too" do
      package = opened("openpyxl")
      {:ok, %{part: part}} = {:ok, Enum.find(package.book.sheets, &(&1.title == "log"))}

      assert {:ok, package} = Xlsx.delete_sheet(package, "log")
      assert Xlsx.titles(package) == ["Costs"]

      {:ok, bin} = Xlsx.encode(package)
      {:ok, entries} = Zip.read(bin)

      refute part in Zip.names(entries)
      refute part(bin, "xl/workbook.xml") =~ ~s(name="log")
      refute part(bin, "[Content_Types].xml") =~ part

      {:ok, reopened} = Xlsx.open(bin)
      assert Xlsx.titles(reopened) == ["Costs"]
    end

    # LibreOffice writes the apostrophe in a sheet's name as &apos;, which
    # Sheetshow's own escaping never does, so the <sheet> element is found by
    # its relationship id rather than by the text of its name.
    test "one whose name the writer escaped its own way still goes whole" do
      {:ok, package} = Xlsx.add_sheet(Xlsx.new(), "Q1's costs")
      {:ok, bin} = Xlsx.encode(package)
      {:ok, entries} = Zip.read(bin)
      {:ok, workbook_xml} = Zip.fetch(entries, "xl/workbook.xml")
      assert workbook_xml =~ ~s(name="Q1's costs")

      escaped = String.replace(workbook_xml, ~s(name="Q1's costs"), ~s(name="Q1&apos;s costs"))
      {:ok, bin} = entries |> Zip.put("xl/workbook.xml", escaped) |> Zip.write()
      {:ok, package} = Xlsx.open(bin)
      assert Xlsx.titles(package) == ["Q1's costs", "Sheet1"]

      %{part: part, rid: rid} = Enum.find(package.book.sheets, &(&1.title == "Q1's costs"))
      {:ok, package} = Xlsx.delete_sheet(package, "Q1's costs")
      {:ok, bin} = Xlsx.encode(package)

      refute part(bin, "xl/workbook.xml") =~ ~s(:id="#{rid}")
      refute part(bin, "xl/workbook.xml") =~ "Q1&apos;s"
      refute part(bin, "xl/_rels/workbook.xml.rels") =~ ~s(Id="#{rid}")
      refute part(bin, "[Content_Types].xml") =~ part
      assert {:ok, reopened} = Xlsx.open(bin)
      assert Xlsx.titles(reopened) == ["Sheet1"]
    end

    test "one that is not there is refused" do
      assert {:error, %Error{reason: :unknown_sheet}} =
               Xlsx.delete_sheet(opened("openpyxl"), "nope")

      assert {:error, %Error{reason: :unknown_sheet}} =
               Xlsx.put_sheet(opened("openpyxl"), "nope", %Sheetshow.Xlsx.Sheet{})
    end

    test "several added at once each get their own part and id" do
      package = opened("openpyxl")
      {:ok, package} = Xlsx.add_sheet(package, "one")
      {:ok, package} = Xlsx.add_sheet(package, "two")
      {:ok, bin} = Xlsx.encode(package)
      {:ok, reopened} = Xlsx.open(bin)

      assert Xlsx.titles(reopened) == ["Costs", "log", "one", "two"]

      parts = Enum.map(reopened.book.sheets, & &1.part)
      assert length(Enum.uniq(parts)) == 4

      rids = Enum.map(reopened.book.sheets, & &1.rid)
      assert length(Enum.uniq(rids)) == 4
    end
  end

  defp extract(xml, tag) do
    [_, rest] = :binary.split(xml, "<#{tag}")
    [inner, _] = :binary.split(rest, "</#{tag}>")
    [_attrs, body] = :binary.split(inner, ">")
    body
  end
end
