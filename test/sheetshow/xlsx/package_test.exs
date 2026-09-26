defmodule Sheetshow.Xlsx.PackageTest do
  # Adding and removing a tab, at the level of the package: everything outside a
  # worksheet that points at one, by position or by relationship. The
  # regressions from the 0.1.6 review pass.
  use ExUnit.Case, async: true

  alias Sheetshow.{Error, Op, Xlsx}
  alias Sheetshow.Xlsx.Zip
  alias Sheetshow.XlsxParts, as: Parts

  @office "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  @package "http://schemas.openxmlformats.org/package/2006/relationships"

  defp three_sheets(opts) do
    Parts.build(
      Parts.sheet(~s(<row r="1"><c r="A1"><v>1</v></c></row>)),
      [title: "A", sheets: [{"B", Parts.sheet("")}, {"C", Parts.sheet("")}]] ++ opts
    )
  end

  defp run(bytes, plan) do
    {workbook, path} = Parts.workbook(bytes)
    result = Sheetshow.run(plan, workbook)
    {result, File.read!(path)}
  end

  describe "deleting a sheet" do
    test "moves what counts sheets by position with it" do
      names =
        "<definedNames>" <>
          ~s(<definedName name="_xlnm.Print_Area" localSheetId="0">'A'!$A$1:$B$2</definedName>) <>
          ~s(<definedName name="_xlnm.Print_Area" localSheetId="2">'C'!$A$1:$B$5</definedName>) <>
          ~s(<definedName name="Rates">A!$A$1</definedName>) <>
          ~s(<definedName name="Kept">'C'!$A$1</definedName>) <>
          ~s(<definedName name="Quoted">'X''A'!$A$1</definedName>) <>
          ~s(<definedName name="Linked">[1]A!$A$1</definedName>) <>
          "</definedNames>"

      bytes =
        three_sheets(
          workbook_pr: ~s(<bookViews><workbookView activeTab="2" firstSheet="2"/></bookViews>),
          after_sheets: names
        )

      {{:ok, _}, written} = run(bytes, [Op.DeleteSheet.new("A")])
      xml = Parts.part(written, "xl/workbook.xml")

      # A's own print area goes, C's counts down, and a name that pointed at A
      # points at nothing, the way a spreadsheet writes that.
      refute xml =~ ~s('A'!$A$1:$B$2)

      assert xml =~
               ~s(<definedName name="_xlnm.Print_Area" localSheetId="1">'C'!$A$1:$B$5</definedName>)

      assert xml =~ ~s(<definedName name="Rates">#REF!$A$1</definedName>)
      assert xml =~ ~s(<definedName name="Kept">'C'!$A$1</definedName>)
      assert xml =~ ~s(<definedName name="Quoted">'X''A'!$A$1</definedName>)
      assert xml =~ ~s(<definedName name="Linked">[1]A!$A$1</definedName>)
      assert xml =~ ~s(activeTab="1")
      assert xml =~ ~s(firstSheet="1")
    end

    test "takes the parts only that sheet reached, so the next sheet does not inherit them" do
      sheet_rels =
        ~s(<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="#{@package}">) <>
          ~s(<Relationship Id="rId1" Type="#{@office}/comments" Target="../comments1.xml"/>) <>
          ~s(<Relationship Id="rId2" Type="#{@office}/hyperlink" Target="https://example.com" TargetMode="External"/>) <>
          "</Relationships>"

      bytes =
        Parts.build(Parts.sheet(""),
          title: "Old",
          sheets: [{"Keep", Parts.sheet("")}],
          parts: [
            {"xl/worksheets/_rels/sheet1.xml.rels", sheet_rels},
            {"xl/comments1.xml", "<comments>a secret note</comments>"}
          ]
        )

      {{:ok, workbook}, written} =
        run(bytes, [Op.DeleteSheet.new("Old"), Op.AddSheet.new("Fresh")])

      {:ok, entries} = Zip.read(written)
      names = Zip.names(entries)

      refute "xl/comments1.xml" in names
      refute "xl/worksheets/_rels/sheet1.xml.rels" in names
      assert Enum.sort(Map.keys(workbook.sheets)) == ["Fresh", "Keep"]
    end

    test "keeps a part something else still points at" do
      shared = fn n ->
        {"xl/worksheets/_rels/sheet#{n}.xml.rels",
         ~s(<Relationships xmlns="#{@package}">) <>
           ~s(<Relationship Id="rId1" Type="#{@office}/image" Target="../media/image1.png"/>) <>
           "</Relationships>"}
      end

      bytes =
        Parts.build(Parts.sheet(""),
          title: "Old",
          sheets: [{"Keep", Parts.sheet("")}],
          parts: [shared.(1), shared.(2), {"xl/media/image1.png", "png"}]
        )

      {{:ok, _}, written} = run(bytes, [Op.DeleteSheet.new("Old")])
      {:ok, entries} = Zip.read(written)
      assert "xl/media/image1.png" in Zip.names(entries)
    end

    test "finds its <sheet> element when a name holds a >" do
      bytes =
        Parts.build(Parts.sheet(""), title: "a>b", sheets: [{"Keep", Parts.sheet("")}])

      {{:ok, _}, written} = run(bytes, [Op.DeleteSheet.new("a>b")])
      {:ok, package} = Xlsx.open(written)
      assert Xlsx.titles(package) == ["Keep"]
      refute Parts.part(written, "xl/workbook.xml") =~ "a>b"
    end
  end

  describe "adding a sheet" do
    test "refuses a name a chart sheet has, or another tab has in another case" do
      bytes =
        Parts.build(Parts.sheet(""), sheets: [{"Costs", Parts.sheet("")}])

      bytes = with_chart_sheet(bytes, "Chart1")

      for title <- ["Chart1", "costs"] do
        assert {{:error, %Error{reason: :duplicate_sheet}}, _} =
                 run(bytes, [Op.AddSheet.new(title)])
      end
    end

    test "refuses a name no spreadsheet can hold" do
      for title <- ["2026/09", "a:b", "[x]", "'quoted'", String.duplicate("x", 32), "tab\there"] do
        assert {{:error, %Error{reason: :unsupported}}, _} =
                 run(Parts.build(Parts.sheet("")), [Op.AddSheet.new(title)])
      end
    end

    test "refuses a workbook part it could not add to, rather than losing the tab" do
      bytes = Parts.build(Parts.sheet(""))
      {:ok, entries} = Zip.read(bytes)
      {:ok, xml} = Zip.fetch(entries, "xl/workbook.xml")

      prefixed =
        xml
        |> String.replace("<workbook xmlns=", "<x:workbook xmlns:x=")
        |> String.replace(~r{<(/?)(sheets|sheet|workbook)\b}, "<\\1x:\\2")
        |> String.replace("<x:x:workbook", "<x:workbook")

      {:ok, bytes} = entries |> Zip.put("xl/workbook.xml", prefixed) |> Zip.write()
      {:ok, package} = Xlsx.open(bytes)
      assert Xlsx.titles(package) == ["Sheet1"]

      assert {{:error, %Error{reason: :unsupported}}, _} = run(bytes, [Op.AddSheet.new("New")])
    end

    test "puts a workbook at the package root's new part beside its others" do
      bytes = Parts.build(Parts.sheet(~s(<row r="1"><c r="A1"><v>1</v></c></row>)), title: "Old")
      bytes = at_root(bytes)

      {{:ok, workbook}, written} = run(bytes, [Op.AddSheet.new("New")])

      {:ok, _} =
        [Sheetshow.Cell.new("New!A1", "mine")] |> Sheetshow.plan!() |> Sheetshow.run(workbook)

      {:ok, again} = Sheetshow.connect(workbook)
      assert {:ok, [[1]]} = Sheetshow.read_rows("Old", again)
      assert {:ok, [["mine"]]} = Sheetshow.read_rows("New", again)
      assert Parts.part(written, "[Content_Types].xml") =~ ~s(PartName="/worksheets/sheet2.xml")
    end
  end

  describe "the zip" do
    test "a part whose bytes do not match its checksum is damage, not content" do
      {:ok, entries} = Zip.read(Parts.build(Parts.sheet("")))

      damaged =
        Enum.map(entries, fn
          %{name: "xl/worksheets/sheet1.xml"} = entry ->
            %{entry | crc: Bitwise.bxor(entry.crc, 1)}

          entry ->
            entry
        end)

      {:ok, bytes} = Zip.write(damaged)
      {:ok, entries} = Zip.read(bytes)

      assert {:error, %Error{reason: :invalid_zip}} =
               Zip.fetch(entries, "xl/worksheets/sheet1.xml")
    end

    test "a name outside ASCII is marked UTF-8, and stays so" do
      {:ok, entries} = Zip.read(Parts.build(Parts.sheet("")))
      {:ok, bytes} = entries |> Zip.put("customXml/café.xml", "<x/>") |> Zip.write()

      {:ok, reread} = Zip.read(bytes)
      assert Enum.find(reread, &(&1.name == "customXml/café.xml")).utf8
      {:ok, again} = Zip.write(reread)
      assert Enum.find(elem(Zip.read(again), 1), &(&1.name == "customXml/café.xml")).utf8
    end

    test "a package naming one part twice is refused" do
      {:ok, entries} = Zip.read(Parts.build(Parts.sheet("")))
      twice = entries ++ [List.last(entries)]
      {:ok, bytes} = Zip.write(twice)
      assert {:error, %Error{reason: :invalid_zip}} = Zip.read(bytes)
    end
  end

  # A chart sheet beside the worksheets: a `<sheet>` in the list whose
  # relationship is a chartsheet's, which is not a tab Sheetshow reads.
  defp with_chart_sheet(bytes, title) do
    {:ok, entries} = Zip.read(bytes)
    {:ok, workbook} = Zip.fetch(entries, "xl/workbook.xml")
    {:ok, rels} = Zip.fetch(entries, "xl/_rels/workbook.xml.rels")

    workbook =
      String.replace(
        workbook,
        "</sheets>",
        ~s(<sheet name="#{title}" sheetId="99" r:id="rId99"/></sheets>)
      )

    rels =
      String.replace(
        rels,
        "</Relationships>",
        ~s(<Relationship Id="rId99" Type="#{@office}/chartsheet" Target="chartsheets/sheet1.xml"/></Relationships>)
      )

    {:ok, bytes} =
      entries
      |> Zip.put("xl/workbook.xml", workbook)
      |> Zip.put("xl/_rels/workbook.xml.rels", rels)
      |> Zip.put("xl/chartsheets/sheet1.xml", "<chartsheet/>")
      |> Zip.write()

    bytes
  end

  # The same package with its workbook part at the root rather than under xl/.
  defp at_root(bytes) do
    {:ok, entries} = Zip.read(bytes)

    moved =
      Enum.reduce(entries, [], fn entry, acc ->
        {:ok, content} = Zip.fetch(entries, entry.name)

        name =
          case entry.name do
            "xl/" <> rest -> rest
            other -> other
          end

        content =
          content
          |> String.replace(~s(Target="xl/workbook.xml"), ~s(Target="workbook.xml"))
          |> String.replace(~s(PartName="/xl/), ~s(PartName="/))

        Zip.put(acc, name, content)
      end)

    {:ok, bytes} = Zip.write(moved)
    {:ok, package} = Xlsx.open(bytes)
    assert Xlsx.titles(package) == ["Old"]
    bytes
  end
end
