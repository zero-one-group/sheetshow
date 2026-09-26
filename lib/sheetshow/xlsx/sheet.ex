defmodule Sheetshow.Xlsx.Sheet do
  @moduledoc false
  # A worksheet part: its cells, its column widths and row heights, and the XML
  # on either side of `<sheetData>` kept exactly as it was.
  #
  # That last part is the whole reason this does not simply rebuild a worksheet
  # from the cells it found. Merged cells, conditional formatting, data
  # validation, autofilters, frozen panes, hyperlinks and print setup are all
  # siblings of `<sheetData>` inside this one part, so anything that regenerates
  # the element throws them away, and the schema fixes their order, so they
  # cannot simply be appended back either. Head and tail go back down untouched.

  alias Sheetshow.{A1, Cell, CellError, Coord, Runs, Value}
  alias Sheetshow.Xlsx.{Formula, Strings, Styles, Xml}

  defstruct cells: [],
            col_widths: %{},
            row_heights: %{},
            rows: %{},
            cols: %{},
            head: "",
            tail: "",
            writable: true,
            date1904: false

  # `rows` and `cols` are what a `<row>` and a `<col>` said besides a size: a
  # hidden flag, an outline level, a row's own style, and the size exactly as it
  # was spelled, so an untouched row or column goes back down as it came up
  # rather than as the nearest pixel Sheetshow models. Keyed by index.
  @type attrs :: [{String.t(), String.t()}]
  @type t :: %__MODULE__{
          cells: [Cell.t()],
          col_widths: %{non_neg_integer() => pos_integer()},
          row_heights: %{non_neg_integer() => pos_integer()},
          rows: %{non_neg_integer() => %{extra: attrs(), size: {pos_integer(), attrs()} | nil}},
          cols: %{non_neg_integer() => %{extra: attrs(), size: {pos_integer(), attrs()} | nil}},
          head: binary(),
          tail: binary(),
          writable: boolean(),
          date1904: boolean()
        }

  # What a spreadsheet means by a column width is the number of digits that fit
  # at the default font, and the conversion the spec gives assumes a digit 7
  # pixels wide with 5 pixels of padding. It is approximate by construction,
  # since the real width depends on a font the file only names, so a width that
  # goes out and comes back may differ by a pixel. ECMA-376 part 1, 18.3.1.13.
  @digit 7
  @padding 5

  # A row height is in points, and a point is three quarters of a pixel.
  @points_to_pixels 4 / 3

  # 1904-01-01 less 1899-12-30, in days: how far apart the two date systems start.
  @days_1904 1462

  @errors %{
    "#NULL!" => "NULL_VALUE",
    "#DIV/0!" => "DIVIDE_BY_ZERO",
    "#VALUE!" => "VALUE",
    "#REF!" => "REF",
    "#NAME?" => "NAME",
    "#NUM!" => "NUM",
    "#N/A" => "N_A",
    "#GETTING_DATA" => "LOADING"
  }

  @doc """
  Reads one worksheet. `title` names the sheet the cells belong to; `strings`
  and `styles` are the workbook's, since a cell's text and a cell's kind both
  live outside the part that holds the cell.
  """
  #
  # `date1904` is the workbook's date system: a workbook saved with
  # `<workbookPr date1904="1"/>` counts its days from 1904-01-01, and reading its
  # serials from 1899-12-30 put every date four years and a day out.
  @spec parse(binary(), String.t(), Strings.t(), Styles.t(), boolean()) ::
          {:ok, t()} | {:error, Sheetshow.Error.t()}
  def parse(xml, title, strings, styles, date1904 \\ false) when is_binary(xml) do
    initial = %{
      sheet: title,
      strings: strings,
      styles: styles,
      date1904: date1904,
      in_data: false,
      collecting: nil,
      chars: [],
      phonetic: false,
      inline_xml: nil,
      row: -1,
      col: 0,
      cell: nil,
      cells: [],
      col_widths: %{},
      row_heights: %{},
      rows: %{},
      cols: %{},
      shared: %{},
      # The namespace prefixes the root element declares: an attribute kept to
      # be written back must be one whose prefix is still declared where it goes.
      prefixes: MapSet.new(["xml"]),
      started: false,
      inline_tainted: false
    }

    with {:ok, state} <- Xml.fold(xml, "a worksheet", initial, &event/2) do
      {head, tail} = split(xml)

      {:ok,
       %__MODULE__{
         cells: state.cells |> Enum.reverse() |> members(),
         col_widths: state.col_widths,
         row_heights: state.row_heights,
         rows: state.rows,
         cols: state.cols,
         date1904: date1904,
         head: head,
         tail: tail,
         # `split/1` looks for `<sheetData` in the default namespace, which is
         # how every writer met so far spells it. A worksheet whose elements
         # carry a prefix (`<x:sheetData>`) parses, since the SAX events name
         # elements without one, but cannot be written back through `render/2`,
         # which would leave the original `<x:sheetData>` in place beside a
         # second, unprefixed one. Such a sheet is read-only here.
         writable: :binary.match(xml, "<sheetData") != :nomatch
       }}
    end
  end

  # An array formula or a data table is written on its first cell with the
  # range it fills (`ref`), and the other cells in that range hold only the
  # values it last filled them with. Each of those is marked with the cell whose
  # formula it belongs to, so the writer can tell whether the range still holds
  # nothing but what the formula put there (see `kept/1`).
  defp members(cells) do
    anchors =
      for %Cell{coord: coord, meta: %{formula_attrs: {_value, attrs, _text, _at}}} <- cells,
          {"ref", ref} <- attrs,
          range = bounds(ref),
          range != nil,
          do: {{coord.row, coord.col}, range}

    case anchors do
      [] ->
        cells

      _ ->
        Enum.map(cells, fn %Cell{coord: %Coord{row: row, col: col}} = cell ->
          case Enum.find(anchors, fn {at, range} ->
                 at != {row, col} and inside?(range, row, col)
               end) do
            nil -> cell
            {at, _range} -> %{cell | meta: Map.put(cell.meta, :in_array, at)}
          end
        end)
    end
  end

  defp bounds(ref) do
    case Sheetshow.Range.from_a1(ref) do
      {:ok, %Sheetshow.Range{end_row: last_row, end_col: last_col} = range}
      when is_integer(last_row) and is_integer(last_col) ->
        {range.start_row, range.start_col, last_row, last_col}

      _ ->
        nil
    end
  end

  defp inside?({first_row, first_col, last_row, last_col}, row, col),
    do: row >= first_row and row <= last_row and col >= first_col and col <= last_col

  @doc """
  The worksheet back as XML, and the two tables as they now stand.

  Only `<sheetData>`, `<cols>` and the `<dimension>` hint are written. Every
  other child of `<worksheet>` (the merged cells, the conditional formatting,
  the data validation, the autofilter, the frozen pane, the hyperlinks, the
  print setup) goes back down exactly as it came up, in the order it was in,
  because the schema fixes that order and a reader refuses a worksheet whose
  children are out of it.

  A cell keeps the style index it was read with when its style has not changed,
  so a border or an indent Sheetshow does not model survives a read and a write.
  """
  @spec render(t(), Strings.t(), Styles.t()) :: {iodata(), Strings.t(), Styles.t()}
  def render(%__MODULE__{} = sheet, strings, styles) do
    {rows, strings, styles} = rows(sheet, strings, styles)

    xml = [
      head(sheet),
      "<sheetData>",
      rows,
      "</sheetData>",
      sheet.tail
    ]

    {xml, strings, styles}
  end

  @doc """
  The sheet with rows `first` onwards, `count` of them, taken out, as a
  `Sheetshow.Op.DeleteRows` takes them out of the cells: what a row said about
  itself goes with it, and the rows below move up.
  """
  @spec delete_rows(t(), non_neg_integer(), pos_integer()) :: t()
  def delete_rows(%__MODULE__{rows: rows} = sheet, first, count) do
    moved =
      for {row, attrs} <- rows, row < first or row >= first + count, into: %{} do
        {if(row < first, do: row, else: row - count), attrs}
      end

    %{sheet | rows: moved}
  end

  defp rows(sheet, strings, styles) do
    kept = kept(sheet.cells)
    context = %{date1904: sheet.date1904, kept: kept}

    {cells, strings, styles} =
      sheet.cells
      |> Enum.sort_by(&{&1.coord.row, &1.coord.col})
      |> Enum.reduce({[], strings, styles}, fn cell, {acc, strings, styles} ->
        {rendered, strings, styles} = cell(cell, strings, styles, context)
        {[{cell.coord.row, rendered} | acc], strings, styles}
      end)

    by_row =
      cells
      |> Enum.reverse()
      |> Enum.reject(&(elem(&1, 1) == nil))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    # A row with no cells is still a row when it says something about itself: a
    # height, a hidden flag, an outline level. Writing only the rows that hold a
    # cell dropped those, and a height set on an empty row never landed at all.
    numbers =
      [Map.keys(by_row), Map.keys(sheet.row_heights), Map.keys(sheet.rows)]
      |> Enum.concat()
      |> Enum.uniq()
      |> Enum.sort()

    rendered =
      Enum.flat_map(numbers, fn row ->
        attributes = row_attributes(row, sheet)
        cells = Map.get(by_row, row, [])

        if attributes == [] and cells == [] do
          []
        else
          [[~s(<row r="#{row + 1}"), attributes, ">", cells, "</row>"]]
        end
      end)

    {rendered, strings, styles}
  end

  # The cells whose `<f>` and `<c>` go back with what they said besides the
  # formula: the ones still holding what they were read with, where they were
  # read. A cell a delete moved is not where its `ref` says its range is, so its
  # formula goes down plain; and an array whose range now holds a cell the
  # formula did not fill (a value written into the middle of it) goes down plain
  # too, since a spreadsheet would otherwise fill the range again over the value.
  defp kept(cells) do
    at = Map.new(cells, fn %Cell{coord: coord} = cell -> {{coord.row, coord.col}, cell} end)

    for %Cell{coord: coord, value: value, meta: %{formula_attrs: {value, attrs, _text, origin}}} <-
          cells,
        origin == {coord.row, coord.col},
        range_intact?(attrs, origin, at),
        into: MapSet.new(),
        do: origin
  end

  defp range_intact?(attrs, origin, at) do
    case Enum.find_value(attrs, fn {name, value} -> if name == "ref", do: bounds(value) end) do
      nil ->
        true

      {first_row, first_col, last_row, last_col} ->
        Enum.all?(for(row <- first_row..last_row, col <- first_col..last_col, do: {row, col}), fn
          ^origin -> true
          key -> member?(Map.get(at, key), origin)
        end)
    end
  end

  defp member?(nil, _origin), do: true
  defp member?(%Cell{meta: %{in_array: origin}}, origin), do: true
  defp member?(%Cell{}, _origin), do: false

  # What the row said about itself, and its height: as it was spelled when the
  # height has not changed, so an untouched row keeps its exact points and its
  # own `customHeight` (a `0` there is what lets a reader fit the row to its
  # font), and a new height otherwise, which is always a custom one.
  defp row_attributes(row, sheet) do
    held = Map.get(sheet.rows, row, %{extra: [], size: nil})

    {extra, size} =
      case {Map.get(sheet.row_heights, row), held.size} do
        {nil, _} ->
          {held.extra, []}

        {pixels, {pixels, spelled}} ->
          {held.extra, spelled}

        {pixels, _} ->
          {without(held.extra, ["ht", "customHeight"]),
           [{"ht", number(pixels / @points_to_pixels)}, {"customHeight", "1"}]}
      end

    case extra ++ size do
      [] -> []
      attrs -> Enum.map(attrs, &write_attribute/1)
    end
  end

  defp write_attribute({name, value}), do: [" ", name, ~s(="), Xml.escape(value), ~s(")]

  # A new size replaces whatever the element said about its size, which without
  # one of its own it may still have said (a `customHeight` and no `ht`).
  defp without(attrs, names), do: Enum.reject(attrs, fn {name, _value} -> name in names end)

  # A cell that read as an error and nothing else: its error lives in `meta`, not
  # in `value`, and is written straight back as the `t="e"` cell it came from, so
  # a write to some other cell on the sheet leaves it as it was rather than blank.
  defp cell(
         %Cell{value: nil, meta: %{effective: %CellError{} = error}} = cell,
         strings,
         styles,
         context
       ) do
    style = style(cell)
    {index, styles} = index(cell, style, styles)

    rendered = [
      ~s(<c r="#{ref(cell.coord)}"),
      attribute("s", index),
      extra_attributes(cell, context),
      ~s( t="e"><v>),
      Xml.escape(CellError.to_text(error)),
      "</v></c>"
    ]

    {rendered, strings, styles}
  end

  defp cell(%Cell{} = cell, strings, styles, context) do
    style = style(cell)
    {index, styles} = index(cell, style, styles)
    {type, body, strings} = body(cell, strings, context)
    body = if body == nil, do: nil, else: [formula_element(cell, context), body]

    rendered =
      cond do
        body != nil ->
          [
            ~s(<c r="#{ref(cell.coord)}"),
            attribute("s", index),
            extra_attributes(cell, context),
            type,
            ">",
            body,
            "</c>"
          ]

        index != 0 ->
          [~s(<c r="#{ref(cell.coord)}"), attribute("s", index), "/>"]

        # Nothing to say about this cell at all.
        true ->
          nil
      end

    {rendered, strings, styles}
  end

  # What a `<c>` carried besides its reference, style and type (`cm` for a
  # dynamic array, `vm` for a picture placed in the cell, `ph`), back on the cell
  # while it holds what it was read with; a new value says nothing about them.
  defp extra_attributes(%Cell{meta: %{formula_attrs: _}} = cell, context) do
    if kept?(cell, context), do: cell_attributes(cell), else: []
  end

  defp extra_attributes(%Cell{} = cell, _context), do: cell_attributes(cell)

  defp cell_attributes(%Cell{
         coord: coord,
         value: value,
         meta: %{cell_attrs: {value, attrs, origin}}
       })
       when origin == {coord.row, coord.col},
       do: Enum.map(attrs, &write_attribute/1)

  defp cell_attributes(%Cell{}), do: []

  defp kept?(%Cell{coord: coord}, %{kept: kept}), do: MapSet.member?(kept, {coord.row, coord.col})

  # An array formula, a data table, a formula marked to recalculate every time:
  # the `<f>` said what kind of formula it was in its attributes, and a plain
  # `<f>` in its place is an ordinary formula over one cell. It goes back as it
  # was while the cell holds what it was read with.
  defp formula_element(%Cell{meta: %{formula_attrs: {_value, attrs, text, _at}}} = cell, context) do
    if kept?(cell, context),
      do: ["<f", Enum.map(attrs, &write_attribute/1), ">", Xml.escape(text), "</f>"],
      else: []
  end

  defp formula_element(%Cell{}, _context), do: []

  # A date written without a number format reads back as the number it is, so
  # one that has none gets the format that makes it a date again, the same
  # thing the planner does on the way to Google.
  defp style(%Cell{} = cell), do: Cell.with_number_format(cell).style

  # The index the cell came in with, when it still describes the cell: that is
  # what keeps a border, an indent or a rich run that Sheetshow never modelled.
  defp index(%Cell{meta: meta}, style, styles) do
    original = Map.get(meta, :style_id, 0)

    if Styles.fetch(styles, original).style == style do
      {original, styles}
    else
      Styles.put(styles, style)
    end
  end

  defp attribute(_name, 0), do: ""
  defp attribute(name, value), do: ~s( #{name}="#{value}")

  defp body(%Cell{value: nil}, strings, _context), do: {"", nil, strings}

  # A data table's cells hold values, and its first cell's `<f>` (kept above)
  # says where they came from; the value goes down as the value it is.
  defp body(%Cell{value: {:formula, "=" <> formula}} = cell, strings, context) do
    case formula_element(cell, context) do
      # No cached <v>: nothing here works a formula out, and a result we made up
      # would be worse than one a reader recalculates for itself.
      [] -> {"", ["<f>", Xml.escape(formula), "</f>"], strings}
      _kept -> {"", [], strings}
    end
  end

  defp body(%Cell{value: value}, strings, _context) when is_boolean(value) do
    {~s( t="b"), ["<v>", if(value, do: "1", else: "0"), "</v>"], strings}
  end

  defp body(%Cell{value: value}, strings, _context) when is_number(value),
    do: {"", ["<v>", number(value), "</v>"], strings}

  # A string read from the shared table keeps the entry it came from while its
  # text is unchanged. The table can hold the same text twice, once plain and once
  # with a run of bold in it, and looking the text up again pointed both cells at
  # the first; the other cell's formatting went with it.
  defp body(
         %Cell{value: value, meta: %{string_id: id}} = cell,
         strings,
         context
       )
       when is_binary(value) do
    if Strings.fetch(strings, id) == value do
      {~s( t="s"), ["<v>", Integer.to_string(id), "</v>"], strings}
    else
      body(%{cell | meta: Map.delete(cell.meta, :string_id)}, strings, context)
    end
  end

  # An inline string with runs in it goes back as the runs it was, while its
  # text is unchanged: the bold word, and the phonetic reading beside it.
  defp body(%Cell{value: value, meta: %{inline_xml: {value, xml}}}, strings, _context)
       when is_binary(value) do
    {~s( t="inlineStr"), xml, strings}
  end

  defp body(%Cell{value: value}, strings, _context) when is_binary(value) do
    case Strings.put(strings, value) do
      {:inline, strings} ->
        {~s( t="inlineStr"),
         [~s(<is><t xml:space="preserve">), Xml.escape_string(value), "</t></is>"], strings}

      {index, strings} ->
        {~s( t="s"), ["<v>", Integer.to_string(index), "</v>"], strings}
    end
  end

  defp body(%Cell{value: %struct{} = value} = cell, strings, %{date1904: date1904})
       when struct in [Date, NaiveDateTime, DateTime, Time] do
    # The number as it was read, while the value it made is unchanged and the
    # workbook counts days the way the one it came from did: a serial finer than
    # a millisecond reads as the nearest millisecond, and writing that back moved
    # an untouched cell by a fraction of one. A cell copied from a workbook with
    # the other date system is counted again.
    text =
      case cell.meta do
        %{serial: {^value, spelled, ^date1904}} -> spelled
        _ -> number(to_serial(value, date1904))
      end

    {"", ["<v>", text, "</v>"], strings}
  end

  # Anything else is not a cell value: a CellError arrives in meta, never here.
  defp body(%Cell{}, strings, _context), do: {"", nil, strings}

  # A moment as the serial this workbook counts in. A time of day is the same
  # fraction in either date system. A date is not: a 1904 workbook counts from
  # 1904-01-01, and the 1900 system counts a 29 February 1900 that never was, so
  # every day before 1 March 1900 sits one serial lower than the plain count from
  # 1899-12-30. That is the count Excel and openpyxl read, and the one written.
  #
  # The two counts meet at day 0, which in Excel is "January 0 1900" and in the
  # plain count is 1899-12-30, the day a time of day with no date sits on (it is
  # how Google hands one back typed as a date and time). That day keeps the
  # plain count, so a time of day read, written and read again is itself; the
  # day between it and 1 January, 1899-12-31, is the one no serial can say, and
  # a date on it reads back as 1 January.
  defp to_serial(%Time{} = time, _date1904), do: Value.to_serial(time)
  defp to_serial(moment, true), do: Value.to_serial(moment) - @days_1904

  defp to_serial(moment, false) do
    serial = Value.to_serial(moment)
    days = floor(serial)
    if days >= 2 and days <= 60, do: serial - 1, else: serial
  end

  # And back, for a number the format says is a moment. Whether it is a time of
  # day is read off the serial as the file spells it, before any shift, because
  # a time is the same fraction in both systems.
  defp moment(serial, :time, _date1904) when serial >= 0 and serial < 1,
    do: Value.read_serial(serial, :time)

  defp moment(serial, kind, true), do: Value.read_serial(serial + @days_1904, kind)

  defp moment(serial, kind, false) when serial >= 1 and serial < 60,
    do: Value.read_serial(serial + 1, kind)

  defp moment(serial, kind, false), do: Value.read_serial(serial, kind)

  # to_string/1 on a float gives "1.0e3", which is not what anyone typed.
  defp number(value) when is_integer(value), do: Integer.to_string(value)

  defp number(value) when is_float(value) do
    if value == Float.round(value) and abs(value) < 1.0e15 do
      value |> trunc() |> Integer.to_string()
    else
      # The shortest string that reads back as the same float. Fixed 15 decimals
      # rounded a value smaller than that to zero (1.0e-20 was written as 0), and
      # exponent notation is a perfectly good number in a `<v>`.
      :erlang.float_to_binary(value, [:short])
    end
  end

  defp ref(%Coord{row: row, col: col}), do: A1.col_to_letters(col) <> Integer.to_string(row + 1)

  # --- the head, which holds <cols> and the dimension hint ---

  defp head(sheet) do
    sheet.head |> put_cols(cols(sheet)) |> put_dimension(sheet.cells)
  end

  # Every column's `<col>` as it now stands: what it said besides its width,
  # which goes back as it was (hidden, a style, an outline level), and its width,
  # as spelled when unchanged and as a custom width otherwise. Neighbours that
  # say the same thing share one element, and a column that says nothing has
  # none. Rebuilding from the widths alone dropped a hidden column outright.
  defp cols(sheet) do
    indexes =
      [Map.keys(sheet.col_widths), Map.keys(sheet.cols)] |> Enum.concat() |> Enum.uniq()

    indexes
    |> Enum.sort()
    |> Enum.map(fn col ->
      held = Map.get(sheet.cols, col, %{extra: [], size: nil})

      {extra, size} =
        case {Map.get(sheet.col_widths, col), held.size} do
          {nil, _} ->
            {held.extra, []}

          {pixels, {pixels, spelled}} ->
            {held.extra, spelled}

          {pixels, _} ->
            {without(held.extra, ["width", "customWidth"]),
             [{"width", number(width(pixels))}, {"customWidth", "1"}]}
        end

      {col, extra ++ size}
    end)
    |> Enum.reject(fn {_col, attrs} -> attrs == [] end)
    |> Runs.consecutive(&elem(&1, 0), &elem(&1, 1))
  end

  defp put_cols(head, []) do
    head |> String.replace(~r{<cols\b.*?</cols>}s, "") |> String.replace(~r{<cols\b[^>]*/>}, "")
  end

  defp put_cols(head, runs) do
    cols = [
      "<cols>",
      Enum.map(runs, fn [{first, attrs} | _] = run ->
        {last, _attrs} = List.last(run)

        [
          ~s(<col min="#{first + 1}" max="#{last + 1}"),
          Enum.map(attrs, &write_attribute/1),
          "/>"
        ]
      end),
      "</cols>"
    ]

    cols = IO.iodata_to_binary(cols)

    cond do
      Regex.match?(~r{<cols\b.*?</cols>}s, head) ->
        Regex.replace(~r{<cols\b.*?</cols>}s, head, fn _ -> cols end, global: false)

      Regex.match?(~r{<cols\b[^>]*/>}, head) ->
        Regex.replace(~r{<cols\b[^>]*/>}, head, fn _ -> cols end, global: false)

      # <cols> is the last thing before <sheetData>, so the end of the head is
      # exactly where it belongs.
      true ->
        head <> cols
    end
  end

  defp width(pixels), do: (pixels - @padding) / @digit

  # The dimension is a hint, and a stale one confuses a reader into drawing
  # scrollbars for rows that are not there.
  defp put_dimension(head, []), do: String.replace(head, ~r{<dimension\b[^>]*/>}, "")

  defp put_dimension(head, cells) do
    rows = Enum.map(cells, & &1.coord.row)
    cols = Enum.map(cells, & &1.coord.col)

    ref =
      ref(%Coord{row: Enum.min(rows), col: Enum.min(cols)}) <>
        ":" <> ref(%Coord{row: Enum.max(rows), col: Enum.max(cols)})

    String.replace(head, ~r{<dimension\b[^>]*/>}, ~s(<dimension ref="#{ref}"/>))
  end

  @doc """
  The worksheet XML with `<sheetData>` taken out: everything before it, and
  everything after it. An empty `<sheetData/>` splits the same way.
  """
  @spec split(binary()) :: {binary(), binary()}
  def split(xml) do
    case :binary.split(xml, "<sheetData") do
      [head, rest] ->
        case open_tag(rest) do
          {:self_closing, tail} -> {head, tail}
          {:open, rest} -> {head, drop_to_close(rest)}
        end

      [whole] ->
        {whole, ""}
    end
  end

  # <sheetData>, <sheetData/>, or <sheetData attr="...">: the schema allows no
  # attributes, but reading past them costs nothing and assuming costs a file.
  defp open_tag(rest) do
    case :binary.split(rest, ">") do
      [attrs, after_tag] ->
        if String.ends_with?(attrs, "/"), do: {:self_closing, after_tag}, else: {:open, after_tag}

      [_none] ->
        {:self_closing, ""}
    end
  end

  defp drop_to_close(rest) do
    case :binary.split(rest, "</sheetData>") do
      [_inner, tail] -> tail
      [_only] -> ""
    end
  end

  # --- events ---

  # The prefixes the root element declares arrive before it does.
  defp event({:startPrefixMapping, prefix, _uri}, %{started: false} = state),
    do: %{state | prefixes: MapSet.put(state.prefixes, List.to_string(prefix))}

  # A prefix declared inside an inline string is one its markup, kept as it was
  # spelled, would lose; such a string is written back from its text instead.
  defp event({:startPrefixMapping, _prefix, _uri}, %{inline_xml: xml} = state)
       when is_list(xml),
       do: %{state | inline_tainted: true}

  defp event({:startElement, _uri, _local, _q, _attrs} = event, %{started: false} = state),
    do: event(event, %{state | started: true})

  defp event({:startElement, _uri, ~c"sheetData", _q, _attrs}, state),
    do: %{state | in_data: true}

  defp event({:endElement, _uri, ~c"sheetData", _q}, state), do: %{state | in_data: false}

  # <cols> sits before <sheetData>, and one <col> can size a run of columns.
  # Everything the element says besides its range is kept per column, and its
  # width is modelled in pixels as well when it has a usable one.
  defp event({:startElement, _uri, ~c"col", _q, attrs}, state) do
    with min when is_integer(min) and min > 0 <- Xml.int(attrs, ~c"min"),
         max when is_integer(max) and max >= min <- Xml.int(attrs, ~c"max") do
      {sized, extra} = split_attributes(attrs, ["width", "customWidth"], ["min", "max"], state)

      pixels =
        case Xml.number(attrs, ~c"width") do
          width when is_number(width) -> round(width * @digit + @padding)
          _ -> nil
        end

      # A width no pixel count can hold (zero, say, on a hidden column) is not
      # modelled, and stays with the rest of what the element said.
      {size, extra} =
        if is_integer(pixels) and pixels > 0,
          do: {{pixels, sized}, extra},
          else: {nil, extra ++ sized}

      Enum.reduce((min - 1)..(max - 1)//1, state, fn col, state ->
        widths = if size, do: Map.put(state.col_widths, col, pixels), else: state.col_widths
        %{state | col_widths: widths, cols: Map.put(state.cols, col, %{extra: extra, size: size})}
      end)
    else
      _ -> state
    end
  end

  defp event({:startElement, _uri, ~c"row", _q, attrs}, %{in_data: true} = state) do
    # `r` counts from one and a coordinate counts from zero; a row without one
    # is the row after the last, which is why `row` starts at -1.
    row =
      case Xml.int(attrs, ~c"r") do
        nil -> state.row + 1
        r -> r - 1
      end

    # `spans` is a hint about which cells follow and goes stale with them, so it
    # is not kept; everything else the row says about itself is.
    {sized, extra} = split_attributes(attrs, ["ht", "customHeight"], ["r", "spans"], state)

    {heights, size} =
      case Xml.number(attrs, ~c"ht") do
        height when is_number(height) and height > 0 ->
          pixels = round(height * @points_to_pixels)
          {Map.put(state.row_heights, row, pixels), {pixels, sized}}

        _ ->
          {state.row_heights, nil}
      end

    extra = if size == nil, do: extra ++ sized, else: extra

    rows =
      if extra == [] and size == nil,
        do: state.rows,
        else: Map.put(state.rows, row, %{extra: extra, size: size})

    %{state | row: row, col: 0, row_heights: heights, rows: rows}
  end

  defp event({:startElement, _uri, ~c"c", _q, attrs}, %{in_data: true} = state) do
    {row, col} =
      case Xml.attr(attrs, ~c"r") do
        nil -> {state.row, state.col}
        ref -> reference(ref)
      end

    {_known, extra} = split_attributes(attrs, [], ["r", "s", "t"], state)

    cell = %{
      row: row,
      col: col,
      style: Xml.int(attrs, ~c"s", 0),
      type: Xml.attr(attrs, ~c"t") || "n",
      formula: nil,
      formula_attrs: nil,
      cell_attrs: extra,
      shared: nil,
      text: nil,
      inline: nil,
      inline_xml: nil
    }

    %{state | cell: cell, row: row, col: col}
  end

  # Inside an inline string everything is kept as it was spelled as well as read
  # for its text: runs of bold, a phonetic reading. See `inline/2`.
  defp event({:startElement, _uri, ~c"is", _q, _attrs}, %{cell: cell} = state)
       when is_map(cell),
       do: %{state | inline_xml: [], inline_tainted: false}

  defp event({:endElement, _uri, ~c"is", _q}, %{cell: cell, inline_xml: xml} = state)
       when is_map(cell) and is_list(xml) do
    kept = if state.inline_tainted, do: nil, else: Enum.reverse(xml)
    %{state | inline_xml: nil, cell: %{cell | inline_xml: kept}}
  end

  defp event(event, %{inline_xml: xml} = state) when is_list(xml) do
    state = %{state | inline_xml: [spelled(event, state) | xml]}
    inline(event, state)
  end

  defp event({:startElement, _uri, ~c"v", _q, _attrs}, %{cell: cell} = state) when is_map(cell),
    do: %{state | collecting: :value, chars: []}

  # A shared formula is written once, on the first cell of its range, and the
  # cells below it carry only `t="shared"` and the `si` that says which one. Any
  # other formula keeps what its `<f>` said about it: an array formula's range,
  # a data table's inputs.
  defp event({:startElement, _uri, ~c"f", _q, attrs}, %{cell: cell} = state) when is_map(cell) do
    cell =
      if Xml.attr(attrs, ~c"t") == "shared" do
        %{cell | shared: Xml.attr(attrs, ~c"si")}
      else
        %{cell | formula_attrs: attrs |> split_attributes([], [], state) |> elem(1)}
      end

    %{state | collecting: :formula, chars: [], cell: cell}
  end

  # A SAX parser reports text that is nothing but whitespace as ignorable, which
  # it is not inside a cell: a string of one space is a string of one space.
  defp event({:ignorableWhitespace, chars}, state), do: event({:characters, chars}, state)

  defp event({:characters, _chars}, %{collecting: nil} = state), do: state

  defp event({:characters, chars}, state), do: %{state | chars: [chars | state.chars]}

  defp event({:endElement, _uri, ~c"v", _q}, %{collecting: :value, cell: cell} = state)
       when is_map(cell),
       do: finish(state, :text)

  defp event({:endElement, _uri, ~c"f", _q}, %{collecting: :formula, cell: cell} = state)
       when is_map(cell),
       do: finish(state, :formula)

  defp event({:endElement, _uri, ~c"c", _q}, %{cell: cell} = state) when is_map(cell) do
    {cell, state} = resolve(cell, state)
    %{state | cell: nil, col: cell.col + 1, cells: prepend(build(cell, state), state.cells)}
  end

  defp event(_event, state), do: state

  # An inline string's text is in <is><t>, and rich text splits it across
  # several <r><t> runs that read as one string. A `<t>` inside `<rPh>` is the
  # phonetic reading of the characters, not more characters.
  defp inline({:startElement, _uri, ~c"rPh", _q, _attrs}, state), do: %{state | phonetic: true}
  defp inline({:endElement, _uri, ~c"rPh", _q}, state), do: %{state | phonetic: false}

  defp inline({:startElement, _uri, ~c"t", _q, _attrs}, %{phonetic: false} = state),
    do: %{state | collecting: :inline, chars: []}

  defp inline({:endElement, _uri, ~c"t", _q}, %{collecting: :inline} = state),
    do: finish(state, :inline)

  defp inline({kind, chars}, %{collecting: :inline} = state)
       when kind in [:characters, :ignorableWhitespace],
       do: %{state | chars: [chars | state.chars]}

  defp inline(_event, state), do: state

  # An event inside `<is>` as the XML that produced it. Characters are escaped
  # again but not SpreadsheetML-decoded, so `_x000D_` goes back as it came.
  defp spelled({:startElement, _uri, _local, qname, attrs}, state) do
    [
      "<",
      qualified(qname),
      Enum.map(elem(split_attributes(attrs, [], [], state), 1), &write_attribute/1),
      ">"
    ]
  end

  defp spelled({:endElement, _uri, _local, qname}, _state), do: ["</", qualified(qname), ">"]

  defp spelled({kind, chars}, _state) when kind in [:characters, :ignorableWhitespace],
    do: Xml.escape(Xml.text([chars]))

  defp spelled(_event, _state), do: []

  defp qualified({[], local}), do: List.to_string(local)
  defp qualified({prefix, local}), do: "#{prefix}:#{local}"

  # An element's attributes as `{name, value}` strings, prefix and all, split into
  # the ones named in `wanted` and the rest, with the ones in `dropped` left out.
  # An attribute whose prefix the root element does not declare is left out too:
  # its declaration was on the element it came from, which is not written back
  # as it was, and an undeclared prefix is a part no reader will parse.
  defp split_attributes(attrs, wanted, dropped, %{prefixes: prefixes}) do
    attrs
    |> Enum.reject(fn {_uri, prefix, _name, _value} ->
      prefix != [] and not MapSet.member?(prefixes, List.to_string(prefix))
    end)
    |> Enum.map(fn {_uri, prefix, name, value} ->
      local = List.to_string(name)
      qname = if prefix == [], do: local, else: "#{prefix}:#{local}"
      {local, {qname, :unicode.characters_to_binary(value)}}
    end)
    |> Enum.reject(fn {local, _pair} -> local in dropped end)
    |> Enum.split_with(fn {local, _pair} -> local in wanted end)
    |> then(fn {kept, rest} -> {Enum.map(kept, &elem(&1, 1)), Enum.map(rest, &elem(&1, 1))} end)
  end

  defp finish(state, key) do
    # An inline string is escaped the SpreadsheetML way, the same as a shared one;
    # a `<v>` and a formula are not, so only the inline run is decoded, each run
    # before it joins the ones before it.
    text =
      case key do
        :inline -> Xml.unescape_string(Xml.text(state.chars))
        _ -> Xml.text(state.chars)
      end

    value =
      case {key, state.cell[key]} do
        {:inline, previous} when is_binary(previous) -> previous <> text
        _ -> text
      end

    %{state | collecting: nil, chars: [], cell: Map.put(state.cell, key, value)}
  end

  defp prepend(nil, cells), do: cells
  defp prepend(cell, cells), do: [cell | cells]

  # An `<f>` with nothing in it is no formula. For a shared one it is the
  # pointer to the formula written on the first cell of the range, which reads
  # here as that formula moved to this cell, exactly as Excel shows it. The
  # first cell comes before the others in the part, so it has been seen; a
  # pointer to one that has not is a damaged file, and the cell keeps its
  # cached value rather than an empty formula.
  defp resolve(%{shared: si, formula: formula} = cell, state) when is_binary(si) do
    case formula do
      text when is_binary(text) and text != "" ->
        {cell, %{state | shared: Map.put(state.shared, si, {text, cell.row, cell.col})}}

      _pointer ->
        case Map.fetch(state.shared, si) do
          {:ok, {text, row, col}} ->
            {%{cell | formula: Formula.translate(text, cell.row - row, cell.col - col)}, state}

          :error ->
            {%{cell | formula: nil}, state}
        end
    end
  end

  # An empty `<f>` that is not shared is a data table's: its cells hold values,
  # and what the `<f>` said about the table is kept beside the value.
  defp resolve(%{formula: ""} = cell, state), do: {%{cell | formula: nil}, state}
  defp resolve(cell, state), do: {cell, state}

  # --- building a cell ---

  # An empty cell is not a cell, here as everywhere else: a <c> with no value,
  # no formula and no style says only that a writer was being thorough.
  defp build(%{formula: nil, text: nil, inline: nil, style: 0, formula_attrs: nil}, _state),
    do: nil

  defp build(cell, state) do
    %{style: style, kind: kind} = Styles.fetch(state.styles, cell.style)
    coord = Coord.new(cell.row, cell.col, state.sheet)
    {computed, kept} = computed(cell, kind, state)

    {value, meta} =
      cond do
        cell.formula != nil ->
          {{:formula, "=" <> cell.formula}, effective(computed)}

        # A cell holding an error and no formula: an error is what a spreadsheet
        # last worked out, never something a person typed, so it goes in `meta`,
        # the same place a formula's error goes, and never becomes a cell value.
        # That is also what keeps `Value.kind/1` from meeting a `%CellError{}` on
        # the way back out and raising on it, and the writer puts it back as the
        # error cell it was.
        match?(%CellError{}, computed) ->
          {nil, %{effective: computed}}

        true ->
          {computed, kept}
      end

    # The index this cell's style came from, so writing it back unchanged can
    # keep a style Sheetshow does not model: a border, an indent, a rich run.
    # Index 0 is the default and the absence of the key means it, which spares
    # a map per cell on the cells that make up most of a workbook.
    meta = if cell.style == 0, do: meta, else: Map.put(meta, :style_id, cell.style)

    # What the `<f>` and the `<c>` said besides the formula and the value, each
    # beside the value it goes with, so the writer can tell whether it still does.
    meta =
      case cell.formula_attrs do
        nil ->
          meta

        attrs ->
          Map.put(meta, :formula_attrs, {value, attrs, cell.formula || "", {cell.row, cell.col}})
      end

    meta =
      case cell.cell_attrs do
        [] -> meta
        attrs -> Map.put(meta, :cell_attrs, {value, attrs, {cell.row, cell.col}})
      end

    %Cell{coord: coord, value: value, style: style, meta: meta}
  end

  defp effective(nil), do: %{}
  defp effective(computed), do: %{effective: computed}

  # What the cell holds, and what to keep beside it so an untouched cell goes back
  # as it came: the shared-string entry it pointed at, the runs of an inline
  # string, the number a moment was read from.
  defp computed(%{type: "s"} = cell, _kind, state) do
    case cell.text && Integer.parse(String.trim(cell.text)) do
      {index, ""} ->
        case Strings.fetch(state.strings, index) do
          nil -> {nil, %{}}
          text -> {text, %{string_id: index}}
        end

      _ ->
        {nil, %{}}
    end
  end

  defp computed(%{type: "inlineStr"} = cell, _kind, _state) do
    # Only an inline string with more in it than one `<t>` is worth keeping as it
    # was spelled; a plain one is written the same way it would be rebuilt.
    case cell.inline_xml do
      xml when is_list(xml) and cell.inline != nil ->
        if rich?(xml),
          do: {cell.inline, %{inline_xml: {cell.inline, ["<is>", xml, "</is>"]}}},
          else: {cell.inline, %{}}

      _ ->
        {cell.inline, %{}}
    end
  end

  defp computed(%{type: "str"} = cell, _kind, _state), do: {cell.text, %{}}

  defp computed(%{type: "b"} = cell, _kind, _state),
    do: {cell.text && String.trim(cell.text) == "1", %{}}

  defp computed(%{type: "e"} = cell, _kind, _state) do
    case cell.text do
      nil -> {nil, %{}}
      text -> {CellError.new(Map.get(@errors, text, text)), %{}}
    end
  end

  # `t="d"` is a date written as ISO 8601 text rather than a serial number, which
  # is what a workbook saved with `iso_dates` does. Both spellings are valid, so
  # the number format does not decide it here: the text does. A time of day
  # arrives as a full timestamp; a bare date has no time.
  defp computed(%{type: "d"} = cell, _kind, _state),
    do: {cell.text && iso_temporal(String.trim(cell.text)), %{}}

  # A number, unless its number format says it is a moment. That is the only
  # thing that says so: 46278 is the 13th of September 2026 or the number
  # 46278, and nothing in the cell itself tells them apart. A number outside the
  # years a date can hold stays the number it is, whatever its format says.
  defp computed(cell, kind, state) do
    case cell.text && Xml.parse_number(cell.text) do
      number when is_number(number) and kind != nil ->
        case moment(number, kind, state.date1904) do
          shifted when is_number(shifted) -> {number, %{}}
          moment -> {moment, %{serial: {moment, String.trim(cell.text), state.date1904}}}
        end

      number when is_number(number) ->
        {number, %{}}

      _ ->
        {nil, %{}}
    end
  end

  # Whether an inline string's markup says more than its text: a run, a
  # phonetic reading, anything but a single `<t>`.
  defp rich?(xml) do
    xml |> IO.iodata_to_binary() |> String.match?(~r/<(?:[\w.-]+:)?(?:r|rPh|phoneticPr)\b/)
  end

  defp iso_temporal(text) do
    case NaiveDateTime.from_iso8601(text) do
      {:ok, naive} ->
        naive

      _ ->
        case Date.from_iso8601(text) do
          {:ok, date} ->
            date

          _ ->
            # A time of day (`12:30:00`), which `iso_dates` writes for a bare
            # time. Without this it read as nil and the cell was erased on write.
            case Time.from_iso8601(text) do
              {:ok, time} -> time
              _ -> nil
            end
        end
    end
  end

  defp reference(ref) do
    {letters, digits} = split_ref(ref, "")

    case Integer.parse(digits) do
      {row, ""} when row > 0 -> {row - 1, A1.letters_to_col(letters)}
      _ -> {0, 0}
    end
  end

  defp split_ref(<<c, rest::binary>>, acc) when c in ?A..?Z or c in ?a..?z,
    do: split_ref(rest, <<acc::binary, c>>)

  defp split_ref(digits, acc), do: {acc, digits}
end
