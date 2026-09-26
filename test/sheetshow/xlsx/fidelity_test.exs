defmodule Sheetshow.Xlsx.FidelityTest do
  # What a write to one cell does to every other cell on the sheet, which should
  # be nothing: each test builds the parts a writer would have left, writes a cell
  # nobody else is looking at, and reads what is left. The regressions from the
  # 0.1.6 review pass.
  use ExUnit.Case, async: true

  alias Sheetshow.{Cell, Op, Table, Workbook, Xlsx}
  alias Sheetshow.XlsxParts, as: Parts

  describe "text" do
    test "a string of spaces, a newline and a leading space read as themselves" do
      strings =
        Parts.strings([
          ~s(<si><t xml:space="preserve"> </t></si>),
          ~s(<si><t xml:space="preserve">\n</t></si>),
          ~s(<si><t xml:space="preserve"> x</t></si>)
        ])

      sheet =
        Parts.sheet(
          ~s(<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c>) <>
            ~s(<c r="C1" t="s"><v>2</v></c><c r="D1" t="inlineStr"><is><t xml:space="preserve">  </t></is></c></row>)
        )

      bytes = Parts.build(sheet, strings: strings)
      assert Enum.map(~w(A1 B1 C1 D1), &Parts.value(bytes, &1)) == [" ", "\n", " x", "  "]

      {_workbook, written, _xml} = Parts.touch(bytes)
      assert Enum.map(~w(A1 B1 C1 D1), &Parts.value(written, &1)) == [" ", "\n", " x", "  "]
    end

    test "and so do the ones Sheetshow writes itself" do
      {workbook, path} = Parts.workbook(Parts.build(Parts.sheet("")))
      values = [" ", "\t", "\n", "  "]

      {:ok, _} =
        values |> Sheetshow.row(sheet: "Sheet1") |> Sheetshow.plan!() |> Sheetshow.run(workbook)

      assert Enum.map(~w(A1 B1 C1 D1), &Parts.value(File.read!(path), &1)) == values
    end

    test "a bold entry and a plain one with the same text keep pointing where they did" do
      strings =
        Parts.strings([
          "<si><r><rPr><b/></rPr><t>same</t></r></si>",
          "<si><t>same</t></si>"
        ])

      sheet =
        Parts.sheet(~s(<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>))

      {_workbook, _written, xml} = Parts.touch(Parts.build(sheet, strings: strings))

      assert xml =~ ~s(<c r="A1" t="s"><v>0</v></c>)
      assert xml =~ ~s(<c r="B1" t="s"><v>1</v></c>)
    end

    test "a new string never points at a rich entry that happens to read the same" do
      strings = Parts.strings(["<si><r><rPr><b/></rPr><t>same</t></r></si>"])
      sheet = Parts.sheet(~s(<row r="1"><c r="A1" t="s"><v>0</v></c></row>))

      {_workbook, written, xml} =
        Parts.touch(Parts.build(sheet, strings: strings), "Sheet1!B1", "same")

      refute xml =~ ~s(<c r="B1" t="s"><v>0</v></c>)
      assert Parts.value(written, "B1") == "same"
    end

    test "an inline string with runs keeps its runs, and its phonetic reading is not its text" do
      rich =
        ~s(<is><r><rPr><b/></rPr><t>bold</t></r><r><t xml:space="preserve"> plain</t></r></is>)

      phonetic = ~s(<is><t>東京</t><rPh sb="0" eb="2"><t>トウキョウ</t></rPh></is>)

      sheet =
        Parts.sheet(
          ~s(<row r="1"><c r="A1" t="inlineStr">#{rich}</c><c r="B1" t="inlineStr">#{phonetic}</c></row>)
        )

      bytes = Parts.build(sheet)
      assert Parts.value(bytes, "A1") == "bold plain"
      assert Parts.value(bytes, "B1") == "東京"

      {_workbook, written, xml} = Parts.touch(bytes)
      assert xml =~ "<rPr><b></b></rPr><t>bold</t>"
      assert Parts.value(written, "B1") == "東京"
    end
  end

  describe "numbers and moments" do
    test "a timestamp shown as a time or a date keeps the part its format hides" do
      styles = Parts.styles([], [{20, ""}, {14, ""}, {45, ""}])

      sheet =
        Parts.sheet(
          ~s(<row r="1"><c r="A1" s="1"><v>45292.75</v></c><c r="B1" s="2"><v>45292.75</v></c>) <>
            ~s(<c r="C1" s="3"><v>1.5</v></c><c r="D1" s="1"><v>0.25</v></c></row>)
        )

      bytes = Parts.build(sheet, styles: styles)
      assert Parts.value(bytes, "A1") == ~N[2024-01-01 18:00:00]
      assert Parts.value(bytes, "B1") == ~N[2024-01-01 18:00:00]
      assert Parts.value(bytes, "D1") == ~T[06:00:00]

      {_workbook, _written, xml} = Parts.touch(bytes)

      for {ref, serial} <- [{"A1", "45292.75"}, {"B1", "45292.75"}, {"C1", "1.5"}, {"D1", "0.25"}] do
        assert xml =~ ~r{<c r="#{ref}" s="\d"><v>#{Regex.escape(serial)}</v>},
               "#{ref} lost part of itself"
      end
    end

    test "a serial finer than a millisecond is written back as it was read" do
      styles = Parts.styles([], [{22, ""}])
      sheet = Parts.sheet(~s(<row r="1"><c r="A1" s="1"><v>45292.123456789012</v></c></row>))

      {_workbook, _written, xml} = Parts.touch(Parts.build(sheet, styles: styles))
      assert xml =~ "<v>45292.123456789012</v>"
    end

    test "a number no date can hold stays a number, and the sheet reads at once" do
      styles = Parts.styles([], [{14, ""}])

      sheet =
        Parts.sheet(
          ~s(<row r="1"><c r="A1" s="1"><v>1E+20</v></c><c r="B1" s="1"><v>1E+308</v></c></row>)
        )

      bytes = Parts.build(sheet, styles: styles)

      task = Task.async(fn -> {Parts.value(bytes, "A1"), Parts.value(bytes, "B1")} end)
      assert {:ok, {1.0e20, 1.0e308}} = Task.yield(task, 2_000)
    end

    test "a 1904 workbook's dates are counted from 1904, both ways" do
      styles = Parts.styles([], [{14, ""}])

      sheet =
        Parts.sheet(
          ~s(<row r="1"><c r="A1" s="1"><v>0</v></c><c r="B1" s="1"><v>44000</v></c></row>)
        )

      bytes = Parts.build(sheet, styles: styles, workbook_pr: ~s(<workbookPr date1904="1"/>))

      assert Parts.value(bytes, "A1") == ~D[1904-01-01]
      assert Parts.value(bytes, "B1") == ~D[2024-06-19]

      {_workbook, written, xml} = Parts.touch(bytes, "Sheet1!C1", ~D[2024-06-19])
      assert xml =~ ~r{<c r="C1" s="\d+"><v>44000</v>}
      assert Parts.value(written, "C1") == ~D[2024-06-19]
    end

    test "a date before March 1900 is the day Excel means by its serial" do
      styles = Parts.styles([], [{14, ""}])

      sheet =
        Parts.sheet(
          ~s(<row r="1"><c r="A1" s="1"><v>1</v></c><c r="B1" s="1"><v>61</v></c></row>)
        )

      bytes = Parts.build(sheet, styles: styles)

      assert Parts.value(bytes, "A1") == ~D[1900-01-01]
      assert Parts.value(bytes, "B1") == ~D[1900-03-01]

      {_workbook, _written, xml} = Parts.touch(bytes, "Sheet1!C1", ~D[1900-01-01])
      assert xml =~ ~r{<c r="C1" s="\d+"><v>1</v>}
    end

    test "a number spelled .5, 5. or with space around it is a number" do
      sheet =
        Parts.sheet(
          ~s(<row r="1"><c r="A1"><v>.5</v></c><c r="B1"><v>5.</v></c><c r="C1"><v> 7 </v></c></row>)
        )

      {_workbook, written, _xml} = Parts.touch(Parts.build(sheet))
      assert Enum.map(~w(A1 B1 C1), &Parts.value(written, &1)) == [0.5, 5.0, 7]
    end
  end

  describe "formulas" do
    test "an array formula, a data table and a spilled array keep what their <f> said" do
      sheet =
        Parts.sheet(
          ~s(<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f t="array" ref="B1:B2">A1:A2*2</f><v>2</v></c>) <>
            ~s|<c r="C1" cm="1"><f t="array" ref="C1:C3">_xlfn.SEQUENCE(3)</f><v>1</v></c></row>| <>
            ~s(<row r="2"><c r="A2"><v>2</v></c><c r="B2"><v>4</v></c>) <>
            ~s(<c r="D2"><f t="dataTable" ref="D2:D3" dt2D="0" dtr="0" r1="A1"/><v>30</v></c></row>)
        )

      {_workbook, _written, xml} = Parts.touch(Parts.build(sheet))

      assert xml =~ ~s(<c r="B1"><f t="array" ref="B1:B2">A1:A2*2</f></c>)
      assert xml =~ ~s|<c r="C1" cm="1"><f t="array" ref="C1:C3">_xlfn.SEQUENCE(3)</f></c>|
      assert xml =~ ~s(<f t="dataTable" ref="D2:D3" dt2D="0" dtr="0" r1="A1"></f><v>30</v>)
    end

    test "a picture placed in a cell keeps its value metadata" do
      sheet = Parts.sheet(~s(<row r="1"><c r="A1" t="e" vm="1"><v>#VALUE!</v></c></row>))
      {_workbook, _written, xml} = Parts.touch(Parts.build(sheet))
      assert xml =~ ~s(<c r="A1" vm="1" t="e"><v>#VALUE!</v></c>)
    end

    test "a shared formula over a sheet named like a cell keeps the sheet it names" do
      sheet =
        Parts.sheet(
          ~s(<row r="1"><c r="A1"><f t="shared" ref="A1:A2" si="0">Q1!B1*2</f></c></row>) <>
            ~s(<row r="2"><c r="A2"><f t="shared" si="0"/></c></row>)
        )

      bytes = Parts.build(sheet, sheets: [{"Q1", Parts.sheet("")}])
      assert Parts.value(bytes, "A2") == {:formula, "=Q1!B2*2"}
    end

    test "the workbook is asked to work its formulas out again when a sheet is written" do
      sheet = Parts.sheet(~s(<row r="1"><c r="A1"><f>1+2</f><v>3</v></c></row>))

      {_workbook, written, _xml} =
        Parts.touch(Parts.build(sheet, after_sheets: ~s(<calcPr calcId="191029"/>)))

      assert Parts.part(written, "xl/workbook.xml") =~
               ~s(<calcPr fullCalcOnLoad="1" calcId="191029"/>)
    end

    test "and gains a calcPr to say so when it had none" do
      {_workbook, written, _xml} = Parts.touch(Parts.build(Parts.sheet("")))
      assert Parts.part(written, "xl/workbook.xml") =~ ~s(</sheets><calcPr fullCalcOnLoad="1"/>)
    end
  end

  describe "rows and columns" do
    test "what a row and a column said about themselves survives a write elsewhere" do
      head =
        ~s(<cols><col min="2" max="2" width="0" hidden="1" customWidth="1"/>) <>
          ~s(<col min="3" max="4" width="12.5" style="1" customWidth="1"/></cols>)

      sheet =
        Parts.sheet(
          ~s(<row r="1" ht="14.4"><c r="A1"><v>1</v></c></row>) <>
            ~s(<row r="2" hidden="1" outlineLevel="1"><c r="A2"><v>2</v></c></row>) <>
            ~s(<row r="3" ht="40" customHeight="1"/>) <>
            ~s(<row r="4" ht="21" customHeight="0"><c r="A4"><v>4</v></c></row>),
          head: head
        )

      {_workbook, _written, xml} = Parts.touch(Parts.build(sheet))

      assert xml =~ ~s(<row r="1" ht="14.4">)
      assert xml =~ ~s(<row r="2" hidden="1" outlineLevel="1">)
      assert xml =~ ~s(<row r="3" ht="40" customHeight="1"></row>)
      assert xml =~ ~s(<row r="4" ht="21" customHeight="0">)
      assert xml =~ ~s(<col min="2" max="2" hidden="1" width="0" customWidth="1"/>)
      assert xml =~ ~s(<col min="3" max="4" style="1" width="12.5" customWidth="1"/>)
    end

    test "a height set on a row with nothing in it lands" do
      {workbook, path} = Parts.workbook(Parts.build(Parts.sheet("")))
      {:ok, _} = Sheetshow.run([Op.SetDimensions.new("Sheet1", :rows, 4..4, 60)], workbook)

      {:ok, back} = Sheetshow.connect(Workbook.xlsx(path))
      {:ok, package} = Xlsx.open(File.read!(path))
      {:ok, sheet} = Xlsx.sheet(package, "Sheet1")
      assert sheet.row_heights == %{4 => 60}
      assert back.sheets == %{"Sheet1" => nil}
    end

    test "a hidden row moves up with its cells when a row above it goes" do
      sheet =
        Parts.sheet(
          ~s(<row r="1"><c r="A1"><v>1</v></c></row>) <>
            ~s(<row r="3" hidden="1"><c r="A3"><v>3</v></c></row>)
        )

      {workbook, path} = Parts.workbook(Parts.build(sheet))
      {:ok, _} = Sheetshow.run([Op.DeleteRows.new("Sheet1", 0..0)], workbook)

      xml = Parts.part(File.read!(path), "xl/worksheets/sheet1.xml")
      assert xml =~ ~s(<row r="2" hidden="1"><c r="A2"><v>3</v></c></row>)
    end
  end

  describe "styles" do
    test "a conditional format's number format is not one a cell can point at" do
      styles =
        Parts.styles(
          [{164, "yyyy-mm-dd"}],
          [{164, ""}],
          ~s(<dxfs count="1"><dxf><numFmt numFmtId="164" formatCode="0.0%"/></dxf></dxfs>)
        )

      sheet = Parts.sheet(~s(<row r="1"><c r="A1" s="1"><v>45292</v></c></row>))
      bytes = Parts.build(sheet, styles: styles)

      assert Parts.value(bytes, "A1") == ~D[2024-01-01]
      assert Parts.cells(bytes)["A1"].style == %{number_format: "yyyy-mm-dd"}
    end

    test "a new cell is not handed a style that says more than it asked for" do
      styles =
        Parts.styles([], [
          {:raw,
           ~s(<xf numFmtId="10" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"/>)}
        ])

      sheet = Parts.sheet(~s(<row r="1"><c r="A1" s="1"><v>0.5</v></c></row>))
      {workbook, path} = Parts.workbook(Parts.build(sheet, styles: styles))

      {:ok, _} =
        [Cell.new("Sheet1!J1", 0.25, %{number_format: "0.00%"})]
        |> Sheetshow.plan!()
        |> Sheetshow.run(workbook)

      xml = Parts.part(File.read!(path), "xl/worksheets/sheet1.xml")
      assert xml =~ ~s(<c r="A1" s="1">)
      refute xml =~ ~s(<c r="J1" s="1")
    end
  end

  describe "a table over a file" do
    test "a date column formatted to show the time reads the moment, not nothing" do
      table = Table.new("t", item: :string, on: :date, at: :datetime)
      {workbook, _path} = Parts.workbook(Parts.build(Parts.sheet("")))

      insert =
        Table.insert(%{item: "Rent", on: ~D[2026-01-05], at: ~N[2026-01-05 10:30:00]}, id: "a")

      {:ok, workbook} =
        Sheetshow.run(Table.create(table) ++ Table.plan!([insert], Table.empty(table)), workbook)

      # A person shows the date column with a time, and the timestamp as a date.
      {:ok, workbook} =
        [
          Cell.new("t!C2", 46_027.5, %{number_format: "yyyy-mm-dd hh:mm"}),
          Cell.new("t!D2", 46_027.4375, %{number_format: "yyyy-mm-dd"})
        ]
        |> Sheetshow.plan!()
        |> Sheetshow.run(workbook)

      {:ok, snapshot} = Table.read(table, workbook)
      [row] = snapshot.rows
      assert row.errors == %{}
      assert row.record.on == ~D[2026-01-05]
      assert row.record.at == ~N[2026-01-05 10:30:00]
    end
  end

  describe "what a cell kept, once the cell has moved or been copied" do
    test "an array formula a delete moved goes down plain, not with a range it no longer has" do
      rows =
        ~s(<row r="1"><c r="A1"><v>1</v></c></row><row r="2"><c r="A2"><v>2</v></c></row>) <>
          ~s(<row r="3"><c r="B3"><f t="array" ref="B3:B4">A1:A2*2</f><v>2</v></c></row>) <>
          ~s(<row r="4"><c r="B4"><v>4</v></c></row>)

      {workbook, path} = Parts.workbook(Parts.build(Parts.sheet(rows)))
      {:ok, _} = Sheetshow.run([Op.DeleteRows.new("Sheet1", 0..0)], workbook)

      xml = Parts.part(File.read!(path), "xl/worksheets/sheet1.xml")
      assert xml =~ ~s(<c r="B2"><f>A1:A2*2</f></c>)
      refute xml =~ ~s(ref="B3:B4")
    end

    test "an array whose range has a value written into it goes down plain" do
      rows =
        ~s(<row r="1"><c r="B1"><f t="array" ref="B1:B3">A1:A3*2</f><v>2</v></c></row>) <>
          ~s(<row r="2"><c r="B2"><v>4</v></c></row><row r="3"><c r="B3"><v>6</v></c></row>)

      {_workbook, _written, xml} =
        Parts.touch(Parts.build(Parts.sheet(rows)), "Sheet1!B2", "mine")

      assert xml =~ ~s(<c r="B1"><f>A1:A3*2</f></c>)
    end

    test "a date copied to a workbook that counts days the other way is counted again" do
      styles = Parts.styles([{164, "yyyy-mm-dd"}], [{164, ""}])

      source =
        Parts.build(Parts.sheet(~s(<row r="1"><c r="A1" s="1"><v>45000</v></c></row>)),
          workbook_pr: ~s(<workbookPr date1904="1"/>),
          styles: styles
        )

      {from, _path} = Parts.workbook(source)
      {:ok, cells} = Sheetshow.read_cells("Sheet1!A1", from)
      {to, path} = Parts.workbook(Parts.build(Parts.sheet("")))
      {:ok, _} = cells |> Sheetshow.plan!() |> Sheetshow.run(to)

      assert Parts.value(File.read!(path), "A1") == hd(cells).value
    end

    test "a time of day read as a date and time comes back as itself" do
      {workbook, path} = Parts.workbook(Parts.build(Parts.sheet("")))
      moment = ~N[1899-12-30 10:00:00]
      {:ok, _} = [Cell.new("Sheet1!A1", moment)] |> Sheetshow.plan!() |> Sheetshow.run(workbook)
      assert Parts.value(File.read!(path), "A1") == moment
    end

    test "an attribute declared on its own element is not written where its prefix is unknown" do
      rows = ~s(<row r="1" xmlns:foo="urn:foo" foo:bar="1"><c r="A1"><v>1</v></c></row>)
      {_workbook, _written, xml} = Parts.touch(Parts.build(Parts.sheet(rows)))
      refute xml =~ "foo:bar"
      assert {:ok, _} = Sheetshow.Xlsx.Xml.fold(xml, "test", nil, fn _, acc -> acc end)
    end

    test "an error somebody typed, read and written back, is the same error" do
      sheet = Parts.sheet(~s(<row r="1"><c r="A1" t="e"><v>#N/A</v></c></row>))
      {workbook, path} = Parts.workbook(Parts.build(sheet))
      {:ok, cells} = Sheetshow.read_cells("Sheet1!A1", workbook)
      {:ok, _} = cells |> Sheetshow.plan!() |> Sheetshow.run(workbook)

      assert Parts.part(File.read!(path), "xl/worksheets/sheet1.xml") =~
               ~s(<c r="A1" t="e"><v>#N/A</v></c>)
    end
  end
end
