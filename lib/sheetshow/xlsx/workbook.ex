defmodule Sheetshow.Xlsx.Workbook do
  @moduledoc false
  # Which parts of the package hold what.
  #
  # None of it is at a fixed path. A worksheet is found by following a
  # relationship from workbook.xml, which is itself found by following one from
  # the package root, and a target may be written relative to the part that
  # names it or absolute from the package root. Both are in the wild, one
  # writer having produced each in the two files this was checked against, so
  # both are read.

  alias Sheetshow.Error
  alias Sheetshow.Xlsx.Xml

  @root_rels "_rels/.rels"

  @office_document "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
  @worksheet "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
  @shared_strings "http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"
  @styles "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"

  @type sheet :: %{title: String.t(), part: String.t()}
  @type t :: %{
          part: String.t(),
          sheets: [sheet()],
          names: [String.t()],
          date1904: boolean(),
          rewritten: boolean(),
          strings: String.t() | nil,
          styles: String.t() | nil
        }

  @doc "Where the root relationships say the workbook part is."
  @spec part(binary()) :: {:ok, String.t()} | {:error, Error.t()}
  def part(rels_xml) do
    with {:ok, rels} <- relationships(rels_xml, @root_rels) do
      case Enum.find(rels, &(&1.type == @office_document)) do
        nil -> {:error, missing("the package names no workbook part", @root_rels)}
        rel -> {:ok, resolve(rel.target, "")}
      end
    end
  end

  @doc """
  The sheets, in the order the workbook lists them, which is tab order, and
  the parts holding the shared strings and the styles.
  """
  @spec parse(binary(), binary(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def parse(workbook_xml, rels_xml, workbook_part) do
    rels_part = rels_path(workbook_part)
    base = directory(workbook_part)

    with {:ok, rels} <- relationships(rels_xml, rels_part),
         {:ok, %{sheets: listed, date1904: date1904}} <- sheets(workbook_xml, workbook_part) do
      by_id = Map.new(rels, &{&1.id, &1})

      sheets =
        for %{title: title, rid: rid} <- listed,
            rel = Map.get(by_id, rid),
            rel != nil and rel.type == @worksheet do
          %{title: title, part: resolve(rel.target, base), rid: rid}
        end

      {:ok,
       %{
         part: workbook_part,
         sheets: sheets,
         # Every name in `<sheets>`, a chart sheet's among them: a name a tab
         # already has is one a new tab cannot take, whatever kind of tab it is.
         names: Enum.map(listed, & &1.title),
         date1904: date1904,
         # Whether a write has changed what a formula could compute, which
         # `Sheetshow.Xlsx.encode/1` answers with a request to recalculate.
         rewritten: false,
         strings: target(rels, @shared_strings, base),
         styles: target(rels, @styles, base)
       }}
    end
  end

  @doc """
  Where a part's own relationships live: `xl/workbook.xml` keeps them in
  `xl/_rels/workbook.xml.rels`.
  """
  @spec rels_path(String.t()) :: String.t()
  def rels_path(part) do
    directory = Path.dirname(part)
    base = Path.basename(part)

    case directory do
      "." -> "_rels/#{base}.rels"
      directory -> "#{directory}/_rels/#{base}.rels"
    end
  end

  @relationships_ns "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  @worksheet_type "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"
  @styles_type "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"

  @doc "A part name under `base` that nothing in the package is using yet."
  @spec free_part([String.t()], String.t(), String.t()) :: String.t()
  #
  # Nor one whose relationships part is still there: a worksheet part that goes
  # while its `_rels` stays would hand its comments, drawings and tables to the
  # next part given its name.
  def free_part(taken, base, prefix) do
    taken = MapSet.new(taken)

    Enum.find_value(1..100_000, fn n ->
      name = if base == "", do: "#{prefix}#{n}.xml", else: "#{base}/#{prefix}#{n}.xml"
      if not MapSet.member?(taken, name) and not MapSet.member?(taken, rels_path(name)), do: name
    end)
  end

  @doc "The directory a part is in, `\"\"` for one at the package root."
  @spec directory(String.t()) :: String.t()
  def directory(part) do
    case Path.dirname(part) do
      "." -> ""
      directory -> directory
    end
  end

  @doc "A relationship id the file is not already using."
  @spec free_rid(binary()) :: String.t()
  def free_rid(rels_xml) do
    next =
      rels_xml
      |> rel_ids()
      |> Enum.map(&rid_number/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    "rId#{next}"
  end

  # Every relationship id the file spells, read the way discovery reads them
  # rather than assumed to be double-quoted `Id="rId1"`: a file that quotes its
  # attributes with `'` read fine but allocated `rId1` over one already taken, so
  # a new sheet's relationship and an existing one shared an id and the old tab
  # resolved to the new, empty part.
  defp rel_ids(rels_xml) do
    case Xml.fold(rels_xml, "xl/_rels/workbook.xml.rels", [], fn
           {:startElement, _uri, ~c"Relationship", _q, attrs}, acc ->
             [Xml.attr(attrs, ~c"Id") | acc]

           _event, acc ->
             acc
         end) do
      {:ok, ids} -> ids
      {:error, _} -> []
    end
  end

  defp rid_number("rId" <> digits) do
    case Integer.parse(digits) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp rid_number(_id), do: nil

  @doc """
  Adds a sheet to the three places a package records one: the relationship that
  says where its part is, the `<sheets>` list that gives it a name and a tab
  position, and the content types that say what kind of part it is. A sheet
  missing from any one of them is a workbook a reader refuses to open.
  """
  #
  # Each of the three is spliced into by a plain string match on its closing tag
  # (`</sheets>`, `</Relationships>`, `</Types>`), which a part that spells its
  # elements with a namespace prefix does not have. Such a part reads fine, so
  # rather than write the worksheet and quietly register it nowhere (a tab
  # `run/2` reported and no later read could find), the add is refused.
  @spec add_sheet(
          %{workbook: binary(), rels: binary(), types: binary()},
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, %{workbook: binary(), rels: binary(), types: binary()}} | {:error, Error.t()}
  def add_sheet(parts, title, part, rid) do
    sheet_id = next_sheet_id(parts.workbook)

    element =
      ~s(<sheet name="#{Xml.escape(title)}" sheetId="#{sheet_id}" ) <>
        ~s(r:id="#{rid}" xmlns:r="#{@relationships_ns}"/>)

    with {:ok, workbook} <-
           inserted(insert_sheet(parts.workbook, element), parts.workbook, "workbook"),
         {:ok, rels} <-
           inserted(
             insert_rel(parts.rels, rid, @worksheet, "worksheets/" <> Path.basename(part)),
             parts.rels,
             "workbook relationships"
           ),
         {:ok, types} <-
           inserted(
             insert_override(parts.types, "/" <> part, @worksheet_type),
             parts.types,
             "content types"
           ) do
      {:ok, %{workbook: workbook, rels: rels, types: types}}
    end
  end

  defp inserted(same, same, what) do
    {:error,
     Error.new(
       :unsupported,
       "the #{what} part spells its elements with a namespace prefix, which Sheetshow reads " <>
         "but cannot add to, so the change is refused rather than written half-registered",
       part: what
     )}
  end

  defp inserted(changed, _original, _what), do: {:ok, changed}

  @doc """
  Takes a sheet back out of all three.

  The `<sheet>` element is found by its relationship id rather than its name:
  a writer may have spelled an apostrophe in the name as `&apos;`, and the id
  is the one thing about the element that is written exactly one way.
  """
  @spec delete_sheet(
          %{workbook: binary(), rels: binary(), types: binary()},
          String.t(),
          String.t(),
          String.t()
        ) ::
          %{workbook: binary(), rels: binary(), types: binary()}
  #
  # Two things in workbook.xml point at a sheet by its position in `<sheets>`
  # rather than by name: a defined name's `localSheetId` (a print area, an
  # autofilter's hidden range) and the workbook view's `activeTab` and
  # `firstSheet`. Taking a sheet out moves every position after it, so those are
  # moved with it: a name that belonged to the deleted sheet goes, one on a later
  # sheet counts down, and a view left past the end comes back inside it. Left
  # alone, the print area of the sheet after the deleted one became the print
  # area of the sheet after that, and LibreOffice refused a file whose name
  # pointed past the last sheet. A name elsewhere that refers to the deleted
  # sheet by name reads `#REF!` instead, which is what a spreadsheet does itself.
  def delete_sheet(parts, part, rid, title) do
    position = sheet_position(parts.workbook, rid)

    workbook =
      parts.workbook
      |> drop_element("sheet", "[\\w.-]+:id", rid)
      |> renumber(position, count_sheets(parts.workbook) - 1, title)

    %{
      workbook: workbook,
      rels: drop_relationship(parts.rels, rid),
      types: drop_override(parts.types, part)
    }
  end

  # Where the sheet with this relationship id sits in `<sheets>`, counting every
  # kind of sheet, since a chart sheet has a position too.
  defp sheet_position(xml, rid) do
    xml
    |> sheet_ids()
    |> Enum.find_index(&(&1 == rid))
  end

  defp count_sheets(xml), do: xml |> sheet_ids() |> length()

  defp sheet_ids(xml) do
    case Xml.fold(xml, "xl/workbook.xml", [], fn
           {:startElement, _uri, ~c"sheet", _q, attrs}, acc -> [Xml.attr(attrs, ~c"id") | acc]
           _event, acc -> acc
         end) do
      {:ok, ids} -> Enum.reverse(ids)
      {:error, _} -> []
    end
  end

  defp renumber(xml, nil, _left, _title), do: xml

  defp renumber(xml, position, left, title) do
    xml
    |> renumber_names(position, title)
    |> renumber_view("activeTab", position, left)
    |> renumber_view("firstSheet", position, left)
  end

  # An attribute value, a quoted run taken whole so a `>` inside one is not the
  # end of the tag.
  @attrs ~S{(?:[^>"']|"[^"]*"|'[^']*')*?}

  defp renumber_names(xml, position, title) do
    Regex.replace(
      ~r{<((?:[\w.-]+:)?)definedName\b(#{@attrs})(/>|>(.*?)</(?:[\w.-]+:)?definedName>)}s,
      xml,
      fn whole, prefix, attrs, _close, content ->
        case local_sheet(attrs) do
          ^position ->
            ""

          local when is_integer(local) and local > position ->
            "<#{prefix}definedName" <>
              set_attr(attrs, "localSheetId", Integer.to_string(local - 1)) <>
              ">" <> unrefer(content, title) <> "</#{prefix}definedName>"

          _other ->
            if content == "" do
              whole
            else
              "<#{prefix}definedName#{attrs}>" <>
                unrefer(content, title) <> "</#{prefix}definedName>"
            end
        end
      end
    )
  end

  defp local_sheet(attrs) do
    case Regex.run(~r{\slocalSheetId\s*=\s*(?:"(\d+)"|'(\d+)')}, attrs) do
      [_, digits] -> String.to_integer(digits)
      [_, "", digits] -> String.to_integer(digits)
      nil -> nil
    end
  end

  defp set_attr(attrs, name, value) do
    Regex.replace(~r{(\s#{name}\s*=\s*)(?:"[^"]*"|'[^']*')}, attrs, fn _, lead ->
      lead <> ~s("#{value}")
    end)
  end

  # A reference to the deleted sheet by name, in a defined name's formula, is a
  # reference to nothing: `#REF!`, the way a spreadsheet writes one. The formula
  # is XML text, so it is compared unescaped and written back escaped.
  #
  # A quoted name is read whole, so `'X''Old'!` (the sheet `X'Old`) is not the
  # sheet `Old` with something in front of it; a bare one has to stand alone,
  # not follow a name character or an external workbook's `[1]`.
  defp unrefer(content, title) do
    text = unescape(content)
    pattern = ~r{'((?:[^']|'')*)'!|(?<![\w.'\]])#{Regex.escape(title)}!}u

    replaced =
      Regex.replace(pattern, text, fn
        "'" <> _ = whole, "" -> whole
        _whole, "" -> "#REF!"
        whole, quoted -> if String.replace(quoted, "''", "'") == title, do: "#REF!", else: whole
      end)

    if replaced == text, do: content, else: IO.iodata_to_binary(Xml.escape(replaced))
  end

  defp unescape(text) do
    Regex.replace(~r/&(?:#(\d+)|#x([0-9A-Fa-f]+)|(amp|lt|gt|quot|apos));/, text, fn
      _, decimal, "", "" -> <<String.to_integer(decimal)::utf8>>
      _, "", hex, "" -> <<String.to_integer(hex, 16)::utf8>>
      _, "", "", "amp" -> "&"
      _, "", "", "lt" -> "<"
      _, "", "", "gt" -> ">"
      _, "", "", "quot" -> ~s(")
      _, "", "", "apos" -> "'"
    end)
  end

  # A view's position after the delete: one less when it was past the deleted
  # sheet, and never past the last sheet left.
  defp renumber_view(xml, name, position, left) do
    Regex.replace(
      ~r{(<(?:[\w.-]+:)?workbookView\b#{@attrs}\s#{name}\s*=\s*)(?:"(\d+)"|'(\d+)')},
      xml,
      fn _whole, lead, double, single ->
        value = String.to_integer(if double == "", do: single, else: double)
        value = if value > position, do: value - 1, else: value
        lead <> ~s("#{max(min(value, left - 1), 0)}")
      end
    )
  end

  @doc """
  workbook.xml asking whoever opens it next to work every formula out again.

  Sheetshow evaluates nothing, and a sheet it has written holds formulas with no
  result beside them and cells other formulas depend on with new values in them.
  A spreadsheet that trusts the results it finds in a file would show the old
  ones; `fullCalcOnLoad` is the flag that says not to. It is what openpyxl sets
  for the same reason, and a spreadsheet clears it when it next saves.
  """
  @spec full_calc_on_load(binary()) :: binary()
  def full_calc_on_load(xml) do
    cond do
      Regex.match?(~r{<(?:[\w.-]+:)?calcPr\b#{@attrs}\sfullCalcOnLoad\s*=}, xml) ->
        Regex.replace(
          ~r{(<(?:[\w.-]+:)?calcPr\b#{@attrs}\sfullCalcOnLoad\s*=\s*)(?:"[^"]*"|'[^']*')},
          xml,
          fn _, lead -> lead <> ~s("1") end,
          global: false
        )

      Regex.match?(~r{<(?:[\w.-]+:)?calcPr\b}, xml) ->
        Regex.replace(
          ~r{<((?:[\w.-]+:)?)calcPr\b},
          xml,
          fn _, prefix -> "<#{prefix}calcPr fullCalcOnLoad=\"1\"" end,
          global: false
        )

      true ->
        insert_calc_pr(xml)
    end
  end

  # `calcPr` comes after `sheets` and the three optional elements that may
  # follow it (`functionGroups`, `externalReferences`, `definedNames`), and
  # before everything else, so it goes after the last of those that is there.
  defp insert_calc_pr(xml) do
    closes = [
      ~r{</(?:[\w.-]+:)?definedNames>|<(?:[\w.-]+:)?definedNames\s*/>},
      ~r{</(?:[\w.-]+:)?externalReferences>},
      ~r{</(?:[\w.-]+:)?functionGroups>|<(?:[\w.-]+:)?functionGroups\b#{@attrs}/>},
      ~r{</(?:[\w.-]+:)?sheets>|<(?:[\w.-]+:)?sheets\s*/>}
    ]

    prefix =
      case Regex.run(~r{<([\w.-]+:)?workbook\b}, xml) do
        [_, prefix] -> prefix
        _ -> ""
      end

    case Enum.find(closes, &Regex.match?(&1, xml)) do
      nil ->
        xml

      pattern ->
        Regex.replace(
          pattern,
          xml,
          fn close -> close <> "<#{prefix}calcPr fullCalcOnLoad=\"1\"/>" end,
          global: false
        )
    end
  end

  @doc """
  The parts a relationships part points at inside the package, resolved: what a
  part stops being reachable through when that relationships part goes. An
  external target (a hyperlink, a linked workbook) is not a part.
  """
  @spec targets(binary(), String.t()) :: [String.t()]
  def targets(rels_xml, rels_part) do
    base = rels_part |> Path.dirname() |> Path.dirname() |> then(&if(&1 == ".", do: "", else: &1))

    case Xml.fold(rels_xml, rels_part, [], fn
           {:startElement, _uri, ~c"Relationship", _q, attrs}, acc ->
             if Xml.attr(attrs, ~c"TargetMode") == "External" or
                  Xml.attr(attrs, ~c"Target") == nil,
                do: acc,
                else: [resolve(Xml.attr(attrs, ~c"Target"), base) | acc]

           _event, acc ->
             acc
         end) do
      {:ok, targets} -> Enum.reverse(targets)
      {:error, _} -> []
    end
  end

  @doc "Takes a part's content-type override out."
  @spec drop_part_override(binary(), String.t()) :: binary()
  def drop_part_override(types, part), do: drop_override(types, part)

  @doc "Declares a styles part that the package did not have."
  @spec add_styles(%{rels: binary(), types: binary()}, String.t(), String.t()) ::
          {:ok, %{rels: binary(), types: binary()}} | {:error, Error.t()}
  def add_styles(parts, part, rid) do
    with {:ok, rels} <-
           inserted(
             insert_rel(parts.rels, rid, @styles, Path.basename(part)),
             parts.rels,
             "workbook relationships"
           ),
         {:ok, types} <-
           inserted(
             insert_override(parts.types, "/" <> part, @styles_type),
             parts.types,
             "content types"
           ) do
      {:ok, %{rels: rels, types: types}}
    end
  end

  @calc_chain "http://schemas.openxmlformats.org/officeDocument/2006/relationships/calcChain"

  @doc """
  The calculation chain part, if the workbook declares one: its relationship id
  and the part it points at, resolved the way any target is. Found by following
  the relationship rather than assuming a filename, because a target may be
  written relative or absolute, and its basename is only `calcChain.xml` by
  convention.
  """
  @spec calc_chain(binary(), String.t()) ::
          {:ok, %{rid: String.t(), part: String.t()} | nil} | {:error, Error.t()}
  def calc_chain(rels_xml, workbook_part) do
    with {:ok, rels} <- relationships(rels_xml, rels_path(workbook_part)) do
      case Enum.find(rels, &(&1.type == @calc_chain)) do
        nil -> {:ok, nil}
        rel -> {:ok, %{rid: rel.id, part: resolve(rel.target, directory(workbook_part))}}
      end
    end
  end

  @doc """
  Takes a part out of the two places besides the zip that name it: the workbook's
  relationship (by id) and the content-type override (by part name). The
  `<Relationship>` and the `<Override>` go together, because a relationship
  pointing at a part that is gone is itself the repair prompt removing the part
  was meant to avoid.
  """
  @spec remove_part(%{workbook: binary(), rels: binary(), types: binary()}, %{
          rid: String.t(),
          part: String.t()
        }) :: %{workbook: binary(), rels: binary(), types: binary()}
  def remove_part(parts, %{rid: rid, part: part}) do
    %{
      workbook: parts.workbook,
      rels: drop_relationship(parts.rels, rid),
      types: drop_override(parts.types, part)
    }
  end

  defp drop_relationship(rels, rid), do: drop_element(rels, "Relationship", "\\bId", rid)

  defp drop_override(types, part), do: drop_element(types, "Override", "\\bPartName", "/" <> part)

  # Removes an empty element identified by one attribute value. An empty element
  # has exactly two spellings, `<El .../>` and `<El ...>` then optional whitespace
  # then `</El>`, so matching both (with a namespace prefix on either tag, either
  # quote style on the attribute, and whitespace around its `=`) is the whole
  # grammar rather than one more guess at it. A part gone while a declaration
  # naming it stayed is the dangling reference a reader offers to repair, and each
  # narrower pattern before this left the declaration behind on a file that spelled
  # it another valid way: a prefix, then single quotes, then a separate closing
  # tag, then whitespace between the tags.
  #
  # The attributes around the one that identifies the element are read as quoted
  # runs, taken whole, because a `>` inside an attribute value is valid XML (a
  # sheet named `a>b`, written by a writer that did not escape it) and ended the
  # tag early for a pattern that stopped at the first one.
  defp drop_element(xml, element, attr, value) do
    escaped = Regex.escape(value)

    String.replace(
      xml,
      ~r{<(?:[\w.-]+:)?#{element}\b#{@attrs}\s#{attr}\s*=\s*(?:"#{escaped}"|'#{escaped}')#{@attrs}(?:/>|>\s*</(?:[\w.-]+:)?#{element}>)},
      ""
    )
  end

  # Functions rather than replacement strings where the pattern is a regex: a
  # title holding `\1` would otherwise be read as a backreference.
  defp insert_sheet(xml, element) do
    cond do
      String.contains?(xml, "</sheets>") ->
        String.replace(xml, "</sheets>", element <> "</sheets>", global: false)

      Regex.match?(~r{<sheets\s*/>}, xml) ->
        wrapped = "<sheets>#{element}</sheets>"
        Regex.replace(~r{<sheets\s*/>}, xml, fn _ -> wrapped end, global: false)

      true ->
        wrapped = "<sheets>#{element}</sheets>"
        Regex.replace(~r{<workbook\b[^>]*>}, xml, &(&1 <> wrapped), global: false)
    end
  end

  defp insert_rel(xml, rid, type, target) do
    element = ~s(<Relationship Id="#{rid}" Type="#{type}" Target="#{target}"/>)
    String.replace(xml, "</Relationships>", element <> "</Relationships>", global: false)
  end

  defp insert_override(xml, part_name, content_type) do
    element = ~s(<Override PartName="#{part_name}" ContentType="#{content_type}"/>)
    String.replace(xml, "</Types>", element <> "</Types>", global: false)
  end

  # A sheetId is a number a workbook gives a tab and never reuses, so the next
  # one is past the highest already there rather than the count of them. Read
  # through the parser, not a `sheetId="..."` regex, so the same file the reader
  # accepts is the file this allocates against.
  defp next_sheet_id(xml) do
    ids =
      case Xml.fold(xml, "xl/workbook.xml", [], fn
             {:startElement, _uri, ~c"sheet", _q, attrs}, acc ->
               case Xml.int(attrs, ~c"sheetId") do
                 nil -> acc
                 id -> [id | acc]
               end

             _event, acc ->
               acc
           end) do
        {:ok, ids} -> ids
        {:error, _} -> []
      end

    Enum.max([0 | ids]) + 1
  end

  defp target(rels, type, base) do
    case Enum.find(rels, &(&1.type == type)) do
      nil -> nil
      rel -> resolve(rel.target, base)
    end
  end

  # A target starting with "/" is from the package root. Anything else is
  # relative to the part that named it, which is the directory holding the
  # `_rels` folder, not the folder itself, so `_rels/.rels` resolves against
  # the package root and `xl/_rels/workbook.xml.rels` against `xl/`.
  defp resolve("/" <> absolute, _base), do: absolute
  defp resolve(relative, ""), do: normalize(relative)
  defp resolve(relative, base), do: normalize(base <> "/" <> relative)

  defp normalize(path), do: path |> Path.expand("/") |> String.trim_leading("/")

  defp relationships(xml, part) do
    Xml.fold(xml, part, [], fn
      {:startElement, _uri, ~c"Relationship", _q, attrs}, acc ->
        [
          %{
            id: Xml.attr(attrs, ~c"Id"),
            type: Xml.attr(attrs, ~c"Type"),
            target: Xml.attr(attrs, ~c"Target")
          }
          | acc
        ]

      _event, acc ->
        acc
    end)
    |> case do
      {:ok, rels} -> {:ok, Enum.reverse(rels)}
      {:error, _} = error -> error
    end
  end

  # The `<sheet>` elements in tab order, and the date system: a workbook that
  # says `<workbookPr date1904="1"/>` counts its days from 1904-01-01.
  defp sheets(xml, part) do
    Xml.fold(xml, part, %{sheets: [], date1904: false}, fn
      {:startElement, _uri, ~c"sheet", _q, attrs}, acc ->
        sheet = %{title: Xml.attr(attrs, ~c"name"), rid: Xml.attr(attrs, ~c"id")}
        %{acc | sheets: [sheet | acc.sheets]}

      {:startElement, _uri, ~c"workbookPr", _q, attrs}, acc ->
        %{acc | date1904: Xml.flag(attrs, ~c"date1904", false)}

      _event, acc ->
        acc
    end)
    |> case do
      {:ok, %{sheets: []}} -> {:error, missing("the workbook lists no sheets", part)}
      {:ok, found} -> {:ok, %{found | sheets: Enum.reverse(found.sheets)}}
      {:error, _} = error -> error
    end
  end

  defp missing(why, part) do
    Error.new(:invalid_xlsx, "this is not a workbook Sheetshow can read: #{why}", part: part)
  end
end
