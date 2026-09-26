defmodule Sheetshow.XlsxParts do
  @moduledoc false
  # A workbook made from the parts a test spells out by hand, for the cases no
  # writer the suite has will produce on request: an array formula, a hidden row,
  # a 1904 date system, a string of one space. What a test asserts is what is in
  # the parts after Sheetshow has written something else, so the parts are the
  # fixture and the file is only how they travel.

  alias Sheetshow.{Coord, Workbook, Xlsx}
  alias Sheetshow.Xlsx.Zip

  @ns "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
  @package "http://schemas.openxmlformats.org/package/2006/relationships"
  @office "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  @types "http://schemas.openxmlformats.org/package/2006/content-types"
  @part "application/vnd.openxmlformats-officedocument.spreadsheetml"

  @doc "A worksheet part: what goes before `<sheetData>`, inside it and after it."
  def sheet(rows, opts \\ []) do
    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
      ~s(<worksheet xmlns="#{@ns}" xmlns:r="#{@office}">) <>
      Keyword.get(opts, :head, "") <>
      "<sheetData>" <> rows <> "</sheetData>" <> Keyword.get(opts, :tail, "") <> "</worksheet>"
  end

  @doc """
  A styles part with `numFmts` and the `cellXfs` after the default one, each
  `{numFmtId, extra attributes}` or `{:raw, xml}`.
  """
  def styles(numfmts, xfs, extra \\ "") do
    formats =
      case numfmts do
        [] ->
          ""

        _ ->
          ~s(<numFmts count="#{length(numfmts)}">) <>
            Enum.map_join(numfmts, fn {id, code} ->
              ~s(<numFmt numFmtId="#{id}" formatCode="#{code}"/>)
            end) <> "</numFmts>"
      end

    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="#{@ns}">) <>
      formats <>
      ~s(<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>) <>
      ~s(<fills count="2"><fill><patternFill patternType="none"/></fill>) <>
      ~s(<fill><patternFill patternType="gray125"/></fill></fills>) <>
      ~s(<borders count="2"><border/><border><left style="thin"/></border></borders>) <>
      ~s(<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>) <>
      ~s(<cellXfs count="#{length(xfs) + 1}"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>) <>
      Enum.map_join(xfs, fn
        {:raw, xml} ->
          xml

        {id, attrs} ->
          ~s(<xf numFmtId="#{id}" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" #{attrs}/>)
      end) <>
      "</cellXfs>" <> extra <> "</styleSheet>"
  end

  @doc "A shared-string part from the `<si>` elements, spelled out."
  def strings(items) do
    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
      ~s(<sst xmlns="#{@ns}" count="#{length(items)}" uniqueCount="#{length(items)}">) <>
      Enum.join(items) <> "</sst>"
  end

  @doc """
  The package. Options: `:styles` and `:strings` (parts), `:workbook_pr` and
  `:after_sheets` (XML spliced into workbook.xml), `:sheets` (more
  `{title, xml}` after the first) and `:title` (the first sheet's).
  """
  def build(sheet_xml, opts \\ []) do
    sheets = [{Keyword.get(opts, :title, "Sheet1"), sheet_xml} | Keyword.get(opts, :sheets, [])]
    numbered = Enum.with_index(sheets, 1)
    n = length(sheets)

    workbook =
      ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
        ~s(<workbook xmlns="#{@ns}" xmlns:r="#{@office}">) <>
        Keyword.get(opts, :workbook_pr, "") <>
        "<sheets>" <>
        Enum.map_join(numbered, fn {{title, _xml}, i} ->
          ~s(<sheet name="#{title}" sheetId="#{i}" r:id="rId#{i}"/>)
        end) <>
        "</sheets>" <> Keyword.get(opts, :after_sheets, "") <> "</workbook>"

    rels =
      ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="#{@package}">) <>
        Enum.map_join(numbered, fn {_sheet, i} ->
          ~s(<Relationship Id="rId#{i}" Type="#{@office}/worksheet" Target="worksheets/sheet#{i}.xml"/>)
        end) <>
        ~s(<Relationship Id="rId#{n + 1}" Type="#{@office}/sharedStrings" Target="sharedStrings.xml"/>) <>
        ~s(<Relationship Id="rId#{n + 2}" Type="#{@office}/styles" Target="styles.xml"/>) <>
        "</Relationships>"

    types =
      ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="#{@types}">) <>
        ~s(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>) <>
        ~s(<Default Extension="xml" ContentType="application/xml"/>) <>
        ~s(<Override PartName="/xl/workbook.xml" ContentType="#{@part}.sheet.main+xml"/>) <>
        Enum.map_join(numbered, fn {_sheet, i} ->
          ~s(<Override PartName="/xl/worksheets/sheet#{i}.xml" ContentType="#{@part}.worksheet+xml"/>)
        end) <>
        ~s(<Override PartName="/xl/sharedStrings.xml" ContentType="#{@part}.sharedStrings+xml"/>) <>
        ~s(<Override PartName="/xl/styles.xml" ContentType="#{@part}.styles+xml"/>) <>
        "</Types>"

    root =
      ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="#{@package}">) <>
        ~s(<Relationship Id="rId1" Type="#{@office}/officeDocument" Target="xl/workbook.xml"/>) <>
        "</Relationships>"

    parts =
      [
        {"[Content_Types].xml", types},
        {"_rels/.rels", root},
        {"xl/workbook.xml", workbook},
        {"xl/_rels/workbook.xml.rels", rels},
        {"xl/sharedStrings.xml", Keyword.get(opts, :strings, strings([]))},
        {"xl/styles.xml", Keyword.get(opts, :styles, styles([], []))}
      ] ++ Enum.map(numbered, fn {{_title, xml}, i} -> {"xl/worksheets/sheet#{i}.xml", xml} end)

    (parts ++ Keyword.get(opts, :parts, []))
    |> Enum.reduce([], fn {name, content}, entries -> Zip.put(entries, name, content) end)
    |> Zip.write()
    |> then(fn {:ok, bytes} -> bytes end)
  end

  @doc "The bytes in a file of their own, and a workbook connected over it."
  def workbook(bytes) do
    directory =
      Path.join(System.tmp_dir!(), "sheetshow-parts-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    path = Path.join(directory, "parts.xlsx")
    File.write!(path, bytes)
    {:ok, workbook} = Sheetshow.connect(Workbook.xlsx(path))
    {workbook, path}
  end

  @doc """
  Writes one cell nobody else is looking at (`J1`, unless told otherwise), and
  gives back the workbook, the file's bytes and the first worksheet part.
  """
  def touch(bytes, a1 \\ "Sheet1!J1", value \\ "touched") do
    {workbook, path} = workbook(bytes)

    {:ok, workbook} =
      [Sheetshow.Cell.new(a1, value)] |> Sheetshow.plan!() |> Sheetshow.run(workbook)

    written = File.read!(path)
    {workbook, written, part(written, "xl/worksheets/sheet1.xml")}
  end

  @doc "One part of a package, inflated."
  def part(bytes, name) do
    {:ok, entries} = Zip.read(bytes)
    {:ok, xml} = Zip.fetch(entries, name)
    xml
  end

  @doc "A sheet's cells, by A1 reference."
  def cells(bytes, title \\ "Sheet1") do
    {:ok, package} = Xlsx.open(bytes)
    {:ok, sheet} = Xlsx.sheet(package, title)
    Map.new(sheet.cells, &{Coord.to_a1(%{&1.coord | sheet: nil}), &1})
  end

  @doc "A cell's value, by A1 reference."
  def value(bytes, a1, title \\ "Sheet1"),
    do: bytes |> cells(title) |> Map.fetch!(a1) |> Map.fetch!(:value)
end
