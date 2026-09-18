defmodule Sheetshow.Xlsx do
  @moduledoc """
  An `.xlsx` workbook, as cells.

  An open package holds the file's parts still compressed, knows which sheets
  it has and where they are, and has read the two tables a cell needs to make
  sense of itself: the shared strings and the styles. Its sheets are not read
  until something asks for one.

  That last part matters. A workbook's cells are spread across one part per
  sheet, and reading them all is the one cost that grows with the file: the
  zip work is flat, but the XML is not. `memory/1` reads them all; a workbook
  over the file, through `Sheetshow.Workbook.xlsx/2`, reads only the tabs a
  plan or a range names.

      {:ok, package} = Sheetshow.Xlsx.open(File.read!("costs.xlsx"))
      Sheetshow.Xlsx.titles(package)
      ["Costs", "log"]

  A cell's value is what was entered, as everywhere else in Sheetshow: a
  formula reads back as a formula, with what the workbook last worked it out to
  in `meta.effective`. Nothing here evaluates anything, so that cached answer is
  only as fresh as the program that wrote the file, which is what
  `Sheetshow.Backend.supports?(workbook, :evaluates_formulas)` says out loud.

  This module is the read side of the codec. Writing goes through
  `Sheetshow.Workbook.xlsx/2` and `Sheetshow.run/2`, which rewrite one tab of
  the file and copy everything else across untouched.
  """

  alias Sheetshow.{Error, Memory, Result}
  alias Sheetshow.Xlsx.{Sheet, Strings, Styles, Workbook, Zip}

  @root_rels "_rels/.rels"
  @content_types "[Content_Types].xml"

  @empty_sheet ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
                 ~s(<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">) <>
                 ~s(<sheetData/></worksheet>)

  @spreadsheet_ns "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
  @package_rels_ns "http://schemas.openxmlformats.org/package/2006/relationships"
  @office_rels_ns "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

  @new_content_types ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
                       ~s(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">) <>
                       ~s(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>) <>
                       ~s(<Default Extension="xml" ContentType="application/xml"/>) <>
                       ~s(<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>) <>
                       ~s(<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>) <>
                       ~s(<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>) <>
                       ~s(</Types>)

  @new_root_rels ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
                   ~s(<Relationships xmlns="#{@package_rels_ns}">) <>
                   ~s(<Relationship Id="rId1" Type="#{@office_rels_ns}/officeDocument" Target="xl/workbook.xml"/>) <>
                   ~s(</Relationships>)

  @new_workbook ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
                  ~s(<workbook xmlns="#{@spreadsheet_ns}" xmlns:r="#{@office_rels_ns}">) <>
                  ~s(<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>)

  @new_workbook_rels ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
                       ~s(<Relationships xmlns="#{@package_rels_ns}">) <>
                       ~s(<Relationship Id="rId1" Type="#{@office_rels_ns}/worksheet" Target="worksheets/sheet1.xml"/>) <>
                       ~s(<Relationship Id="rId2" Type="#{@office_rels_ns}/sharedStrings" Target="sharedStrings.xml"/>) <>
                       ~s(</Relationships>)

  @new_shared_strings ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) <>
                        ~s(<sst xmlns="#{@spreadsheet_ns}" count="0" uniqueCount="0"/>)

  @enforce_keys [:entries, :book, :strings, :styles]
  defstruct [:entries, :book, :strings, :styles]

  @typedoc """
  An open workbook: its zip entries, its workbook part, and the two tables a
  cell needs to make sense of itself: the shared strings and the styles.

  Opaque, and the fields are `term()` here for the same reason: every one of
  them is an xlsx internal this library does not promise anything about. Make
  one with `open/1` and hand it back to the functions here.
  """
  @opaque t :: %__MODULE__{
            entries: term(),
            book: term(),
            strings: term(),
            styles: term()
          }

  @doc """
  Opens a package: its parts, its sheets, its shared strings and its styles.
  Reads no worksheet.

  A workbook with no shared strings and no styles is ordinary, since one writer
  puts its text in the cells rather than in a table, so neither being there is
  not an error.
  """
  @spec open(binary()) :: {:ok, t()} | {:error, Error.t()}
  def open(binary) when is_binary(binary) do
    with {:ok, entries} <- Zip.read(binary),
         {:ok, root_rels} <- Zip.fetch(entries, @root_rels),
         {:ok, part} <- Workbook.part(root_rels),
         {:ok, workbook_xml} <- Zip.fetch(entries, part),
         {:ok, rels_xml} <- Zip.fetch(entries, Workbook.rels_path(part)),
         {:ok, book} <- Workbook.parse(workbook_xml, rels_xml, part),
         {:ok, strings} <- strings(entries, book),
         {:ok, styles} <- styles(entries, book) do
      {:ok, %__MODULE__{entries: entries, book: book, strings: strings, styles: styles}}
    end
  end

  @doc false
  # An empty workbook: the smallest package a reader will open, with one sheet
  # called `Sheet1` and a shared string table waiting to be filled. No
  # styles.xml: one is written the first time a cell needs a style that is not
  # the default, along with the relationship and content type that declare it.
  #
  # Undocumented, like every write here: the documented way to write a
  # workbook is `Sheetshow.Workbook.xlsx/2` and `Sheetshow.run/2`.
  @spec new() :: t()
  def new do
    entries =
      Enum.reduce(
        [
          {@content_types, @new_content_types},
          {@root_rels, @new_root_rels},
          {"xl/workbook.xml", @new_workbook},
          {"xl/_rels/workbook.xml.rels", @new_workbook_rels},
          {"xl/sharedStrings.xml", @new_shared_strings},
          {"xl/worksheets/sheet1.xml", @empty_sheet}
        ],
        [],
        fn {name, content}, entries -> Zip.put(entries, name, content) end
      )

    %__MODULE__{
      entries: entries,
      book: %{
        part: "xl/workbook.xml",
        sheets: [%{title: "Sheet1", part: "xl/worksheets/sheet1.xml", rid: "rId1"}],
        strings: "xl/sharedStrings.xml",
        styles: nil
      },
      strings: Strings.shared(),
      styles: Styles.new()
    }
  end

  @doc "The sheet titles, sorted, as every `titles/1` in Sheetshow answers."
  @spec titles(t()) :: [String.t()]
  def titles(%__MODULE__{book: book}), do: book.sheets |> Enum.map(& &1.title) |> Enum.sort()

  @doc false
  # Reads one sheet: its cells, its column widths and row heights, and the XML
  # on either side of its `<sheetData>`, which is what lets it be written back
  # without losing the things that live beside its cells.
  #
  # Undocumented on purpose: what it hands back is a worksheet part, whose
  # fields are xlsx internals rather than anything the library promises. The
  # backend uses this to materialise only the sheets a plan names, which is what
  # keeps a 100 MB workbook out of memory. `memory/1` is the documented way in.
  @spec sheet(t(), String.t()) :: {:ok, Sheet.t()} | {:error, Error.t()}
  def sheet(%__MODULE__{} = package, title) do
    case Enum.find(package.book.sheets, &(&1.title == title)) do
      nil ->
        {:error, unknown(package, title)}

      %{part: part} ->
        with {:ok, xml} <- Zip.fetch(package.entries, part) do
          Sheet.parse(xml, title, package.strings, package.styles)
        end
    end
  end

  @doc """
  Every sheet, as a `Sheetshow.Memory`: the whole workbook in the shape the
  rest of the library already runs ops against and reads cells out of.

  This is the read that grows with the file. A workbook over the file reads
  one tab at a time instead.
  """
  @spec memory(t()) :: {:ok, Memory.t()} | {:error, Error.t()}
  def memory(%__MODULE__{} = package) do
    Result.reduce(titles(package), Memory.new(), fn title, memory ->
      with {:ok, sheet} <- sheet(package, title), do: {:ok, put(memory, title, sheet)}
    end)
  end

  @doc """
  Opens a package and reads every sheet, in one call.

      {:ok, memory} = Sheetshow.Xlsx.decode(File.read!("costs.xlsx"))
      Sheetshow.Memory.titles(memory)
      ["Costs", "log"]
  """
  @spec decode(binary()) :: {:ok, Memory.t()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) do
    with {:ok, package} <- open(binary), do: memory(package)
  end

  @doc "Same as `decode/1`, raising on failure."
  @spec decode!(binary()) :: Memory.t()
  def decode!(binary), do: binary |> decode() |> Error.unwrap!()

  @doc false
  # Writes a sheet back into the package. Undocumented for the reason `sheet/2`
  # is: it takes the worksheet part that gave you, cells changed.
  #
  # What that part carries besides its cells is the XML either side of
  # `<sheetData>`, which is how everything that lives beside a sheet's cells
  # survives being written through.
  #
  # The package comes back with whatever the write added to the shared strings
  # and the styles, so it is the one to write next: these grow as cells are
  # written, and only ever at the end.
  @spec put_sheet(t(), String.t(), Sheet.t()) :: {:ok, t()} | {:error, Error.t()}
  def put_sheet(%__MODULE__{} = package, title, %Sheet{} = sheet) do
    case Enum.find(package.book.sheets, &(&1.title == title)) do
      nil ->
        {:error, unknown(package, title)}

      # See `Sheetshow.Xlsx.Sheet.parse/4`: a worksheet written with a
      # namespace prefix can be read but not put back, and saying so beats a
      # part with two `sheetData` elements in it.
      %{part: part} when not sheet.writable ->
        {:error,
         Error.new(
           :unsupported,
           "#{part} spells its elements with a namespace prefix, which Sheetshow reads " <>
             "but does not write: the sheet #{inspect(title)} is read-only here",
           part: part,
           sheet: title
         )}

      %{part: part} ->
        {xml, strings, styles} = Sheet.render(sheet, package.strings, package.styles)

        {:ok,
         %{
           package
           | entries: Zip.put(package.entries, part, IO.iodata_to_binary(xml)),
             strings: strings,
             styles: styles
         }}
    end
  end

  @doc false
  # Adds a sheet: a worksheet part, the relationship that says where it is, the
  # entry in the workbook that gives it a name and a tab position, and the
  # content type that says what kind of part it is. A sheet missing from any one
  # of those is a workbook a reader refuses to open.
  @spec add_sheet(t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def add_sheet(%__MODULE__{} = package, title) do
    if Enum.any?(package.book.sheets, &(&1.title == title)) do
      {:error,
       Error.new(:duplicate_sheet, "the sheet #{inspect(title)} is already there", sheet: title)}
    else
      with {:ok, parts} <- parts(package) do
        base = Path.dirname(package.book.part) <> "/worksheets"
        part = Workbook.free_part(Zip.names(package.entries), base, "sheet")
        rid = Workbook.free_rid(parts.rels)
        written = Workbook.add_sheet(parts, title, part, rid)

        entries =
          package.entries
          |> Zip.put(part, @empty_sheet)
          |> put_parts(package, written)

        book = %{
          package.book
          | sheets: package.book.sheets ++ [%{title: title, part: part, rid: rid}]
        }

        {:ok, %{package | entries: entries, book: book}}
      end
    end
  end

  @doc false
  # Removes a sheet, and everything in the package that pointed at it.
  @spec delete_sheet(t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def delete_sheet(%__MODULE__{} = package, title) do
    case Enum.find(package.book.sheets, &(&1.title == title)) do
      nil ->
        {:error, unknown(package, title)}

      %{part: part, rid: rid} ->
        with {:ok, parts} <- parts(package) do
          written = Workbook.delete_sheet(parts, part, rid)

          entries =
            package.entries
            |> Zip.delete(part)
            |> put_parts(package, written)

          book = %{
            package.book
            | sheets: Enum.reject(package.book.sheets, &(&1.title == title))
          }

          {:ok, %{package | entries: entries, book: book}}
        end
    end
  end

  @doc false
  # The package as bytes. The two tables go down only if something was added to
  # them, `calcChain.xml` goes out because it names cells by position and a
  # stale one makes a reader offer to repair the file, and every part nothing
  # touched is copied across still compressed.
  @spec encode(t()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(%__MODULE__{} = package) do
    with {:ok, package} <- write_strings(package),
         {:ok, package} <- write_styles(package),
         {:ok, package} <- drop_calc_chain(package) do
      Zip.write(package.entries)
    end
  end

  # calcChain.xml names cells by position, so a stale one makes a reader offer to
  # repair the file. It goes out with the relationship and the content-type
  # override that name it, so nothing is left pointing at a part that is gone,
  # which is itself a repair prompt. The part is found by following the
  # relationship rather than assuming its name. A workbook that declares no
  # calcChain still loses a conventionally named one, exactly as before.
  defp drop_calc_chain(package) do
    fallback = %{package | entries: Zip.delete(package.entries, assumed_calc_chain(package))}

    with {:ok, parts} <- parts(package),
         {:ok, %{part: part} = chain} <- Workbook.calc_chain(parts.rels, package.book.part) do
      entries =
        package.entries
        |> Zip.delete(part)
        |> put_parts(package, Workbook.remove_part(parts, chain))

      {:ok, %{package | entries: entries}}
    else
      _ -> {:ok, fallback}
    end
  end

  defp assumed_calc_chain(package) do
    Path.dirname(package.book.part) <> "/calcChain.xml"
  end

  defp write_strings(%{book: %{strings: part}} = package) when is_binary(part) do
    if Strings.added?(package.strings) do
      xml = IO.iodata_to_binary(Strings.render(package.strings))
      {:ok, %{package | entries: Zip.put(package.entries, part, xml)}}
    else
      {:ok, package}
    end
  end

  # A workbook that shares no strings gains no table: its cells carry their own
  # text, which is what `Strings.put/2` answered while they were being written.
  defp write_strings(package), do: {:ok, package}

  defp write_styles(package) do
    cond do
      not Styles.added?(package.styles) and is_binary(package.book.styles) ->
        {:ok, package}

      is_binary(package.book.styles) ->
        xml = IO.iodata_to_binary(Styles.render(package.styles))
        {:ok, %{package | entries: Zip.put(package.entries, package.book.styles, xml)}}

      # No styles.xml at all, and something now needs one.
      Styles.added?(package.styles) ->
        with {:ok, parts} <- parts(package) do
          part = Path.dirname(package.book.part) <> "/styles.xml"
          rid = Workbook.free_rid(parts.rels)
          written = Workbook.add_styles(parts, part, rid)
          xml = IO.iodata_to_binary(Styles.render(package.styles))

          entries =
            package.entries
            |> Zip.put(part, xml)
            |> put_parts(package, Map.put(written, :workbook, parts.workbook))

          {:ok, %{package | entries: entries, book: %{package.book | styles: part}}}
        end

      true ->
        {:ok, package}
    end
  end

  # workbook.xml, its relationships and the content types, which the three
  # package-level edits all work on together.
  defp parts(%__MODULE__{} = package) do
    with {:ok, workbook} <- Zip.fetch(package.entries, package.book.part),
         {:ok, rels} <- Zip.fetch(package.entries, Workbook.rels_path(package.book.part)),
         {:ok, types} <- Zip.fetch(package.entries, @content_types) do
      {:ok, %{workbook: workbook, rels: rels, types: types}}
    end
  end

  defp put_parts(entries, package, parts) do
    entries
    |> Zip.put(package.book.part, parts.workbook)
    |> Zip.put(Workbook.rels_path(package.book.part), parts.rels)
    |> Zip.put(@content_types, parts.types)
  end

  defp unknown(package, title), do: Error.unknown_sheet(title, titles(package))

  defp put(memory, title, %Sheet{} = sheet) do
    Memory.put_sheet(memory, title, sheet.cells, sheet.col_widths, sheet.row_heights)
  end

  defp strings(_entries, %{strings: nil}), do: {:ok, Strings.new()}

  defp strings(entries, %{strings: part}) do
    if Zip.member?(entries, part) do
      with {:ok, xml} <- Zip.fetch(entries, part), do: Strings.parse(xml)
    else
      {:ok, Strings.new()}
    end
  end

  defp styles(_entries, %{styles: nil}), do: {:ok, Styles.new()}

  defp styles(entries, %{styles: part}) do
    if Zip.member?(entries, part) do
      with {:ok, xml} <- Zip.fetch(entries, part), do: Styles.parse(xml)
    else
      {:ok, Styles.new()}
    end
  end
end
