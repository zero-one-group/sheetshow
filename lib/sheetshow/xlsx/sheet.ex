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
  alias Sheetshow.Xlsx.{Strings, Styles, Xml}

  defstruct cells: [], col_widths: %{}, row_heights: %{}, head: "", tail: ""

  @type t :: %__MODULE__{
          cells: [Cell.t()],
          col_widths: %{non_neg_integer() => pos_integer()},
          row_heights: %{non_neg_integer() => pos_integer()},
          head: binary(),
          tail: binary()
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
  @spec parse(binary(), String.t(), Strings.t(), Styles.t()) ::
          {:ok, t()} | {:error, Sheetshow.Error.t()}
  def parse(xml, title, strings, styles) when is_binary(xml) do
    initial = %{
      sheet: title,
      strings: strings,
      styles: styles,
      in_data: false,
      collecting: nil,
      chars: [],
      row: -1,
      col: 0,
      cell: nil,
      cells: [],
      col_widths: %{},
      row_heights: %{}
    }

    with {:ok, state} <- Xml.fold(xml, "a worksheet", initial, &event/2) do
      {head, tail} = split(xml)

      {:ok,
       %__MODULE__{
         cells: Enum.reverse(state.cells),
         col_widths: state.col_widths,
         row_heights: state.row_heights,
         head: head,
         tail: tail
       }}
    end
  end

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
      head(sheet.head, sheet.col_widths, sheet.cells),
      "<sheetData>",
      rows,
      "</sheetData>",
      sheet.tail
    ]

    {xml, strings, styles}
  end

  defp rows(sheet, strings, styles) do
    {cells, strings, styles} =
      sheet.cells
      |> Enum.sort_by(&{&1.coord.row, &1.coord.col})
      |> Enum.reduce({[], strings, styles}, fn cell, {acc, strings, styles} ->
        {rendered, strings, styles} = cell(cell, strings, styles)
        {[{cell.coord.row, rendered} | acc], strings, styles}
      end)

    rows =
      cells
      |> Enum.reverse()
      |> Enum.reject(&(elem(&1, 1) == nil))
      |> Enum.chunk_by(&elem(&1, 0))
      |> Enum.map(fn [{row, _} | _] = group ->
        [
          ~s(<row r="#{row + 1}"),
          height(sheet.row_heights[row]),
          ">",
          Enum.map(group, &elem(&1, 1)),
          "</row>"
        ]
      end)

    {rows, strings, styles}
  end

  # A height is kept in points, and customHeight is what stops a reader
  # deciding the row should fit its font instead.
  defp height(nil), do: ""

  defp height(pixels) do
    ~s( ht="#{number(pixels / @points_to_pixels)}" customHeight="1")
  end

  defp cell(%Cell{} = cell, strings, styles) do
    style = style(cell)
    {index, styles} = index(cell, style, styles)
    {type, body, strings} = body(cell.value, strings)

    rendered =
      cond do
        body != nil ->
          [~s(<c r="#{ref(cell.coord)}"), attribute("s", index), type, ">", body, "</c>"]

        index != 0 ->
          [~s(<c r="#{ref(cell.coord)}"), attribute("s", index), "/>"]

        # Nothing to say about this cell at all.
        true ->
          nil
      end

    {rendered, strings, styles}
  end

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

  defp body(nil, strings), do: {"", nil, strings}

  defp body({:formula, "=" <> formula}, strings) do
    # No cached <v>: nothing here works a formula out, and a result we made up
    # would be worse than one a reader recalculates for itself.
    {"", ["<f>", Xml.escape(formula), "</f>"], strings}
  end

  defp body(value, strings) when is_boolean(value) do
    {~s( t="b"), ["<v>", if(value, do: "1", else: "0"), "</v>"], strings}
  end

  defp body(value, strings) when is_number(value),
    do: {"", ["<v>", number(value), "</v>"], strings}

  defp body(value, strings) when is_binary(value) do
    case Strings.put(strings, value) do
      {:inline, strings} ->
        {~s( t="inlineStr"), [~s(<is><t xml:space="preserve">), Xml.escape(value), "</t></is>"],
         strings}

      {index, strings} ->
        {~s( t="s"), ["<v>", Integer.to_string(index), "</v>"], strings}
    end
  end

  defp body(%struct{} = value, strings) when struct in [Date, NaiveDateTime, DateTime, Time] do
    {"", ["<v>", number(Value.to_serial(value)), "</v>"], strings}
  end

  # Anything else is not a cell value: a CellError arrives in meta, never here.
  defp body(_other, strings), do: {"", nil, strings}

  # to_string/1 on a float gives "1.0e3", which is not what anyone typed.
  defp number(value) when is_integer(value), do: Integer.to_string(value)

  defp number(value) when is_float(value) do
    if value == Float.round(value) and abs(value) < 1.0e15 do
      value |> trunc() |> Integer.to_string()
    else
      :erlang.float_to_binary(value, [:compact, decimals: 15])
    end
  end

  defp ref(%Coord{row: row, col: col}), do: A1.col_to_letters(col) <> Integer.to_string(row + 1)

  # --- the head, which holds <cols> and the dimension hint ---

  defp head(head, col_widths, cells) do
    head |> put_cols(col_widths) |> put_dimension(cells)
  end

  defp put_cols(head, widths) when map_size(widths) == 0 do
    head |> String.replace(~r{<cols\b.*?</cols>}s, "") |> String.replace(~r{<cols\b[^>]*/>}, "")
  end

  defp put_cols(head, widths) do
    cols = [
      "<cols>",
      widths
      |> Enum.sort()
      |> Runs.consecutive(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn [{first, pixels} | _] = run ->
        {last, _pixels} = List.last(run)

        ~s(<col min="#{first + 1}" max="#{last + 1}" width="#{number(width(pixels))}" customWidth="1"/>)
      end),
      "</cols>"
    ]

    cols = IO.iodata_to_binary(cols)

    cond do
      Regex.match?(~r{<cols\b.*?</cols>}s, head) ->
        String.replace(head, ~r{<cols\b.*?</cols>}s, cols)

      Regex.match?(~r{<cols\b[^>]*/>}, head) ->
        String.replace(head, ~r{<cols\b[^>]*/>}, cols)

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

  defp event({:startElement, _uri, ~c"sheetData", _q, _attrs}, state),
    do: %{state | in_data: true}

  defp event({:endElement, _uri, ~c"sheetData", _q}, state), do: %{state | in_data: false}

  # <cols> sits before <sheetData>, and one <col> can size a run of columns.
  defp event({:startElement, _uri, ~c"col", _q, attrs}, state) do
    with min when is_integer(min) <- Xml.int(attrs, ~c"min"),
         max when is_integer(max) <- Xml.int(attrs, ~c"max"),
         width when is_number(width) <- Xml.number(attrs, ~c"width"),
         pixels when pixels > 0 <- round(width * @digit + @padding) do
      widths = Enum.reduce((min - 1)..(max - 1)//1, state.col_widths, &Map.put(&2, &1, pixels))
      %{state | col_widths: widths}
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

    heights =
      case Xml.number(attrs, ~c"ht") do
        height when is_number(height) and height > 0 ->
          Map.put(state.row_heights, row, round(height * @points_to_pixels))

        _ ->
          state.row_heights
      end

    %{state | row: row, col: 0, row_heights: heights}
  end

  defp event({:startElement, _uri, ~c"c", _q, attrs}, %{in_data: true} = state) do
    {row, col} =
      case Xml.attr(attrs, ~c"r") do
        nil -> {state.row, state.col}
        ref -> reference(ref)
      end

    cell = %{
      row: row,
      col: col,
      style: Xml.int(attrs, ~c"s", 0),
      type: Xml.attr(attrs, ~c"t") || "n",
      formula: nil,
      text: nil,
      inline: nil
    }

    %{state | cell: cell, row: row, col: col}
  end

  defp event({:startElement, _uri, ~c"v", _q, _attrs}, %{cell: cell} = state) when is_map(cell),
    do: %{state | collecting: :value, chars: []}

  defp event({:startElement, _uri, ~c"f", _q, _attrs}, %{cell: cell} = state) when is_map(cell),
    do: %{state | collecting: :formula, chars: []}

  # An inline string's text is in <is><t>, and rich text splits it across
  # several <r><t> runs that read as one string.
  defp event({:startElement, _uri, ~c"t", _q, _attrs}, %{cell: cell} = state) when is_map(cell),
    do: %{state | collecting: :inline, chars: []}

  defp event({:characters, _chars}, %{collecting: nil} = state), do: state

  defp event({:characters, chars}, state), do: %{state | chars: [chars | state.chars]}

  defp event({:endElement, _uri, ~c"v", _q}, %{collecting: :value, cell: cell} = state)
       when is_map(cell),
       do: finish(state, :text)

  defp event({:endElement, _uri, ~c"f", _q}, %{collecting: :formula, cell: cell} = state)
       when is_map(cell),
       do: finish(state, :formula)

  defp event({:endElement, _uri, ~c"t", _q}, %{collecting: :inline, cell: cell} = state)
       when is_map(cell),
       do: finish(state, :inline)

  defp event({:endElement, _uri, ~c"c", _q}, %{cell: cell} = state) when is_map(cell) do
    %{state | cell: nil, col: cell.col + 1, cells: prepend(build(cell, state), state.cells)}
  end

  defp event(_event, state), do: state

  defp finish(state, key) do
    text = Xml.text(state.chars)

    value =
      case {key, state.cell[key]} do
        {:inline, previous} when is_binary(previous) -> previous <> text
        _ -> text
      end

    %{state | collecting: nil, chars: [], cell: Map.put(state.cell, key, value)}
  end

  defp prepend(nil, cells), do: cells
  defp prepend(cell, cells), do: [cell | cells]

  # --- building a cell ---

  # An empty cell is not a cell, here as everywhere else: a <c> with no value,
  # no formula and no style says only that a writer was being thorough.
  defp build(%{formula: nil, text: nil, inline: nil, style: 0}, _state), do: nil

  defp build(cell, state) do
    %{style: style, kind: kind} = Styles.fetch(state.styles, cell.style)
    coord = Coord.new(cell.row, cell.col, state.sheet)
    computed = computed(cell, kind, state.strings)

    {value, meta} =
      case cell.formula do
        nil -> {computed, %{}}
        formula -> {{:formula, "=" <> formula}, effective(computed)}
      end

    # The index this cell's style came from, so writing it back unchanged can
    # keep a style Sheetshow does not model: a border, an indent, a rich run.
    # Index 0 is the default and the absence of the key means it, which spares
    # a map per cell on the cells that make up most of a workbook.
    meta = if cell.style == 0, do: meta, else: Map.put(meta, :style_id, cell.style)

    %Cell{coord: coord, value: value, style: style, meta: meta}
  end

  defp effective(nil), do: %{}
  defp effective(computed), do: %{effective: computed}

  defp computed(%{type: "s"} = cell, _kind, strings) do
    case cell.text && Integer.parse(cell.text) do
      {index, ""} -> Strings.fetch(strings, index)
      _ -> nil
    end
  end

  defp computed(%{type: "inlineStr"} = cell, _kind, _strings), do: cell.inline
  defp computed(%{type: "str"} = cell, _kind, _strings), do: cell.text

  defp computed(%{type: "b"} = cell, _kind, _strings), do: cell.text == "1"

  defp computed(%{type: "e"} = cell, _kind, _strings) do
    case cell.text do
      nil -> nil
      text -> CellError.new(Map.get(@errors, text, text))
    end
  end

  # A number, unless its number format says it is a moment. That is the only
  # thing that says so: 46278 is the 13th of September 2026 or the number
  # 46278, and nothing in the cell itself tells them apart.
  defp computed(cell, kind, _strings) do
    case cell.text && Xml.parse_number(cell.text) do
      number when is_number(number) and kind != nil -> Value.from_serial(number, kind)
      number when is_number(number) -> number
      _ -> nil
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
