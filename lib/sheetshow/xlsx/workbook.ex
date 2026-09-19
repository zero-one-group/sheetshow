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
         {:ok, listed} <- sheets(workbook_xml, workbook_part) do
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
  def free_part(taken, base, prefix) do
    Enum.find_value(1..100_000, fn n ->
      name = "#{base}/#{prefix}#{n}.xml"
      if name not in taken, do: name
    end)
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
  @spec add_sheet(
          %{workbook: binary(), rels: binary(), types: binary()},
          String.t(),
          String.t(),
          String.t()
        ) ::
          %{workbook: binary(), rels: binary(), types: binary()}
  def add_sheet(parts, title, part, rid) do
    sheet_id = next_sheet_id(parts.workbook)

    element =
      ~s(<sheet name="#{Xml.escape(title)}" sheetId="#{sheet_id}" ) <>
        ~s(r:id="#{rid}" xmlns:r="#{@relationships_ns}"/>)

    %{
      workbook: insert_sheet(parts.workbook, element),
      rels:
        insert_rel(parts.rels, rid, @worksheet, Path.basename(part) |> then(&"worksheets/#{&1}")),
      types: insert_override(parts.types, "/" <> part, @worksheet_type)
    }
  end

  @doc """
  Takes a sheet back out of all three.

  The `<sheet>` element is found by its relationship id rather than its name:
  a writer may have spelled an apostrophe in the name as `&apos;`, and the id
  is the one thing about the element that is written exactly one way.
  """
  @spec delete_sheet(
          %{workbook: binary(), rels: binary(), types: binary()},
          String.t(),
          String.t()
        ) ::
          %{workbook: binary(), rels: binary(), types: binary()}
  def delete_sheet(parts, part, rid) do
    %{
      workbook: drop_element(parts.workbook, "sheet", "[\\w.-]+:id", rid),
      rels: drop_relationship(parts.rels, rid),
      types: drop_override(parts.types, part)
    }
  end

  @doc "Declares a styles part that the package did not have."
  @spec add_styles(%{rels: binary(), types: binary()}, String.t(), String.t()) ::
          %{rels: binary(), types: binary()}
  def add_styles(parts, part, rid) do
    %{
      rels: insert_rel(parts.rels, rid, @styles, Path.basename(part)),
      types: insert_override(parts.types, "/" <> part, @styles_type)
    }
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

  # Removes an empty element identified by one attribute value, tolerant of every
  # spelling the SAX discovery accepts: a namespace prefix on the element
  # (`<r:Relationship>`), either quote style on the attribute, whitespace around
  # its `=`, and a self-closing tag or a separate closing one. Narrower patterns
  # left the declaration behind when a file spelled it another valid way, and a
  # part gone while a declaration naming it stayed is the dangling reference a
  # reader offers to repair.
  defp drop_element(xml, element, attr, value) do
    escaped = Regex.escape(value)

    String.replace(
      xml,
      ~r{<(?:[\w.-]+:)?#{element}\b[^>]*?#{attr}\s*=\s*(?:"#{escaped}"|'#{escaped}')[^>]*?(?:/>|></(?:[\w.-]+:)?#{element}>)},
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

  defp directory(part) do
    case Path.dirname(part) do
      "." -> ""
      directory -> directory
    end
  end

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

  defp sheets(xml, part) do
    Xml.fold(xml, part, [], fn
      {:startElement, _uri, ~c"sheet", _q, attrs}, acc ->
        [%{title: Xml.attr(attrs, ~c"name"), rid: Xml.attr(attrs, ~c"id")} | acc]

      _event, acc ->
        acc
    end)
    |> case do
      {:ok, []} -> {:error, missing("the workbook lists no sheets", part)}
      {:ok, sheets} -> {:ok, Enum.reverse(sheets)}
      {:error, _} = error -> error
    end
  end

  defp missing(why, part) do
    Error.new(:invalid_xlsx, "this is not a workbook Sheetshow can read: #{why}", part: part)
  end
end
