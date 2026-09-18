defmodule Sheetshow.Xlsx.Styles do
  @moduledoc false
  # styles.xml as a lookup from a cell's `s=` index to the style Sheetshow
  # models and the kind of value its number format implies.
  #
  # The second half is what makes reading possible at all: a date in xlsx is a
  # number, and the only thing that says otherwise is its number format. A cell
  # holding 46278 is the 13th of September 2026 or the number 46278 depending
  # on a number two indirections away.

  alias Sheetshow.Xlsx.Xml

  defstruct formats: %{},
            number_formats: %{},
            lookup: %{},
            source: nil,
            counts: %{fonts: 0, fills: 0, xfs: 0},
            added: %{numfmts: [], fonts: [], fills: [], xfs: []}

  @type entry :: %{style: map(), kind: :date | :datetime | :time | nil}
  @type t :: %__MODULE__{formats: %{non_neg_integer() => entry()}}

  @font_keys [:bold, :italic, :underline, :strikethrough, :font_size, :font_family, :color]

  # Fills 0 and 1 are none and gray125 by convention, and Excel expects to find
  # them there; a styles.xml made from nothing has to start with both.
  @skeleton """
  <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
  <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
  <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
  <fills count="2"><fill><patternFill patternType="none"/></fill>\
  <fill><patternFill patternType="gray125"/></fill></fills>\
  <borders count="1"><border/></borders>\
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
  <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
  </styleSheet>
  """

  # The built-in number formats a file never spells out. Only the ones that
  # decide a value's kind matter here; the rest are numbers either way.
  # ECMA-376 part 1, 18.8.30.
  # The built-in date and time formats a file leaves unsaid, by id. What each one
  # *means* is not kept here: `kind/1` reads it off the code, the same as for a
  # custom format, so there is one classifier and no chance of the table and the
  # classifier disagreeing (46, `[h]:mm:ss`, is elapsed and reads as a number).
  @builtin %{
    14 => "mm-dd-yy",
    15 => "d-mmm-yy",
    16 => "d-mmm",
    17 => "mmm-yy",
    18 => "h:mm AM/PM",
    19 => "h:mm:ss AM/PM",
    20 => "h:mm",
    21 => "h:mm:ss",
    22 => "m/d/yy h:mm",
    45 => "mm:ss",
    46 => "[h]:mm:ss",
    47 => "mmss.0"
  }

  @builtin_numbers %{
    1 => "0",
    2 => "0.00",
    3 => "#,##0",
    4 => "#,##0.00",
    9 => "0%",
    10 => "0.00%",
    11 => "0.00E+00",
    12 => "# ?/?",
    13 => "# ??/??",
    37 => "#,##0 ;(#,##0)",
    38 => "#,##0 ;[Red](#,##0)",
    39 => "#,##0.00;(#,##0.00)",
    40 => "#,##0.00;[Red](#,##0.00)",
    48 => "##0.0E+0",
    49 => "@"
  }

  @horizontal %{"left" => :left, "center" => :center, "centre" => :center, "right" => :right}
  @vertical %{"top" => :top, "center" => :middle, "middle" => :middle, "bottom" => :bottom}

  @doc """
  The empty table, for a workbook with no styles.xml at all, which is a
  workbook where every cell is `s="0"` and plain.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      formats: %{0 => %{style: %{}, kind: nil}},
      lookup: %{%{} => 0},
      source: @skeleton,
      counts: %{fonts: 1, fills: 2, xfs: 1}
    }
  end

  @doc """
  The index to write for a style, and the table to write out afterwards.

  A style the table already describes keeps its index. A new one is
  **appended** (a font, a fill and a number format if it needs them, then the
  `cellXf` that ties them together), because every cell in every sheet we did
  not touch points into these lists by position. Renumbering them would restyle
  a spreadsheet nobody asked us to touch.
  """
  @spec put(t(), map()) :: {non_neg_integer(), t()}
  def put(%__MODULE__{} = styles, style) when is_map(style) do
    case Map.fetch(styles.lookup, style) do
      {:ok, index} -> {index, styles}
      :error -> mint(styles, style)
    end
  end

  @doc "Whether anything has been added since the table was read."
  @spec added?(t()) :: boolean()
  def added?(%__MODULE__{added: added}), do: Enum.any?(Map.values(added), &(&1 != []))

  @doc """
  Whether a new style can be written into this table. A styles part whose elements
  carry a namespace prefix (`<x:styleSheet>`) reads fine, but a new `<xf>` would
  have to be spliced in with that prefix on itself and every child, which the
  writer does not do; splicing an unprefixed one would leave an index the file
  cannot resolve. Such a part is read-only, the way a prefixed worksheet is, and
  `Sheetshow.Xlsx` refuses a write that would add a style to it.
  """
  @spec writable?(t()) :: boolean()
  def writable?(%__MODULE__{source: source}) when is_binary(source),
    do: not Regex.match?(~r/<[A-Za-z0-9_.-]+:styleSheet\b/, source)

  def writable?(%__MODULE__{}), do: true

  @doc """
  styles.xml as it should now be written: the original, with what `put/2`
  appended spliced into each list and the counts brought up to date.

  Spliced rather than rebuilt, because the original says things Sheetshow does
  not model, such as a border, an indent or a font's scheme, and a table
  rebuilt from what we understood would quietly drop them from every cell that
  used them.
  """
  @spec render(t()) :: iodata()
  def render(%__MODULE__{} = styles) do
    styles.source
    |> splice("numFmts", styles.added.numfmts, :first)
    |> splice("fonts", styles.added.fonts, :present)
    |> splice("fills", styles.added.fills, :present)
    |> splice("cellXfs", styles.added.xfs, :present)
  end

  defp mint(styles, style) do
    {numfmt, styles} = numfmt_id(styles, Map.get(style, :number_format))
    {font, styles} = font_id(styles, Map.take(style, @font_keys))
    {fill, styles} = fill_id(styles, Map.get(style, :background))

    index = styles.counts.xfs + length(styles.added.xfs)
    element = xf(numfmt, font, fill, style)

    styles = %{
      styles
      | added: Map.update!(styles.added, :xfs, &(&1 ++ [element])),
        lookup: Map.put(styles.lookup, style, index),
        formats:
          Map.put(styles.formats, index, %{
            style: style,
            kind: kind(Map.get(style, :number_format))
          })
    }

    {index, styles}
  end

  # A pattern the workbook already has a number for keeps that number, whether
  # it is one of the built-in ones every file leaves unsaid or a custom one
  # this file spelled out. Only a pattern nobody has seen needs an id, and
  # custom ids start at 164 because everything below is spoken for.
  defp numfmt_id(styles, nil), do: {0, styles}

  defp numfmt_id(styles, code) do
    builtin =
      Map.new(Map.merge(@builtin_numbers, @builtin), fn {id, c} -> {c, id} end)

    custom = Map.new(styles.number_formats, fn {id, c} -> {c, id} end)

    cond do
      id = Map.get(custom, code) ->
        {id, styles}

      id = Map.get(builtin, code) ->
        {id, styles}

      true ->
        id = next_numfmt_id(styles)
        element = ~s(<numFmt numFmtId="#{id}" formatCode="#{Xml.escape(code)}"/>)

        {id,
         %{
           styles
           | number_formats: Map.put(styles.number_formats, id, code),
             added: Map.update!(styles.added, :numfmts, &(&1 ++ [element]))
         }}
    end
  end

  defp next_numfmt_id(styles) do
    max(163, styles.number_formats |> Map.keys() |> Enum.max(fn -> 163 end)) + 1
  end

  defp font_id(styles, font) when map_size(font) == 0, do: {0, styles}

  defp font_id(styles, font) do
    element = [
      "<font>",
      if(font[:bold], do: "<b/>", else: ""),
      if(font[:italic], do: "<i/>", else: ""),
      if(font[:strikethrough], do: "<strike/>", else: ""),
      if(font[:underline], do: "<u/>", else: ""),
      if(font[:font_size], do: ~s(<sz val="#{font[:font_size]}"/>), else: ""),
      if(font[:color], do: ~s(<color rgb="#{argb(font[:color])}"/>), else: ""),
      if(font[:font_family], do: ~s(<name val="#{Xml.escape(font[:font_family])}"/>), else: ""),
      "</font>"
    ]

    append(styles, :fonts, :fonts, IO.iodata_to_binary(element))
  end

  defp fill_id(styles, nil), do: {0, styles}

  defp fill_id(styles, background) do
    element =
      ~s(<fill><patternFill patternType="solid"><fgColor rgb="#{argb(background)}"/>) <>
        ~s(<bgColor indexed="64"/></patternFill></fill>)

    append(styles, :fills, :fills, element)
  end

  defp append(styles, count_key, added_key, element) do
    id = Map.fetch!(styles.counts, count_key) + length(Map.fetch!(styles.added, added_key))
    {id, %{styles | added: Map.update!(styles.added, added_key, &(&1 ++ [element]))}}
  end

  defp xf(numfmt, font, fill, style) do
    alignment = Map.take(style, [:horizontal, :vertical, :wrap])

    attrs =
      [
        ~s(numFmtId="#{numfmt}" fontId="#{font}" fillId="#{fill}" borderId="0" xfId="0"),
        if(numfmt != 0, do: ~s( applyNumberFormat="1"), else: ""),
        if(font != 0, do: ~s( applyFont="1"), else: ""),
        if(fill != 0, do: ~s( applyFill="1"), else: ""),
        if(alignment != %{}, do: ~s( applyAlignment="1"), else: "")
      ]
      |> IO.iodata_to_binary()

    if alignment == %{} do
      "<xf #{attrs}/>"
    else
      "<xf #{attrs}><alignment#{alignment_attrs(alignment)}/></xf>"
    end
  end

  defp alignment_attrs(alignment) do
    [
      case alignment[:horizontal] do
        nil -> ""
        value -> ~s( horizontal="#{horizontal_name(value)}")
      end,
      case alignment[:vertical] do
        nil -> ""
        value -> ~s( vertical="#{vertical_name(value)}")
      end,
      if(alignment[:wrap] == :wrap, do: ~s( wrapText="1"), else: "")
    ]
    |> IO.iodata_to_binary()
  end

  defp horizontal_name(:center), do: "center"
  defp horizontal_name(value), do: Atom.to_string(value)

  defp vertical_name(:middle), do: "center"
  defp vertical_name(value), do: Atom.to_string(value)

  # "#RRGGBB" as the AARRGGBB an xlsx colour is written in, opaque.
  defp argb("#" <> rgb), do: "FF" <> String.upcase(rgb)

  # Puts new elements at the end of a list, bringing its count with them. A
  # list that is not there at all, or is there but empty and self-closed, has
  # to be opened up first.
  defp splice(xml, _tag, [], _when_absent), do: xml

  defp splice(xml, tag, elements, when_absent) do
    added = IO.iodata_to_binary(elements)

    cond do
      String.contains?(xml, "</#{tag}>") ->
        xml
        |> bump_count(tag, length(elements))
        |> String.replace("</#{tag}>", added <> "</#{tag}>", global: false)

      # Functions rather than replacement strings: a font name or a format
      # code holding `\1` would otherwise be read as a backreference.
      Regex.match?(~r/<#{tag}\b[^>]*\/>/, xml) ->
        opened = open(tag, added, length(elements))
        Regex.replace(~r/<#{tag}\b[^>]*\/>/, xml, fn _ -> opened end, global: false)

      when_absent == :first ->
        opened = open(tag, added, length(elements))
        Regex.replace(~r/<styleSheet\b[^>]*>/, xml, fn root -> root <> opened end, global: false)

      true ->
        String.replace(
          xml,
          "</styleSheet>",
          open(tag, added, length(elements)) <> "</styleSheet>"
        )
    end
  end

  defp open(tag, added, count), do: ~s(<#{tag} count="#{count}">#{added}</#{tag}>)

  defp bump_count(xml, tag, added) do
    Regex.replace(
      ~r/<#{tag}(\s[^>]*?)?\scount="(\d+)"/,
      xml,
      fn _whole, before, count ->
        ~s(<#{tag}#{before} count="#{String.to_integer(count) + added}")
      end,
      global: false
    )
  end

  @doc """
  What the cell style at this index looks like, and what kind of value its
  number format says it holds. An index the file does not have is plain rather
  than an error: a style that is not there cannot be applied wrongly.
  """
  @spec fetch(t(), non_neg_integer() | nil) :: entry()
  def fetch(%__MODULE__{formats: formats}, index) do
    Map.get(formats, index || 0, %{style: %{}, kind: nil})
  end

  @doc """
  Reads styles.xml.

  Four lists matter: `numFmts` (the custom number formats), `fonts`, `fills`
  and `cellXfs`, the last of which is what a cell's `s=` indexes into and which
  points at the other three by position.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, Sheetshow.Error.t()}
  def parse(xml) when is_binary(xml) do
    initial = %{
      section: nil,
      number_formats: %{},
      fonts: [],
      fills: [],
      xfs: [],
      font: nil,
      fill: nil,
      xf: nil
    }

    with {:ok, state} <- Xml.fold(xml, "xl/styles.xml", initial, &event/2) do
      {:ok, assemble(state, xml)}
    end
  end

  # A colour inside a <font> is the text colour; inside a <fill> it is the
  # background, and only the foreground of the pattern is the one people mean.
  defp event({:startElement, _uri, ~c"numFmt", _q, attrs}, state) do
    id = Xml.int(attrs, ~c"numFmtId")
    code = Xml.attr(attrs, ~c"formatCode")

    if is_integer(id) and is_binary(code) do
      %{state | number_formats: Map.put(state.number_formats, id, code)}
    else
      state
    end
  end

  defp event({:startElement, _uri, ~c"fonts", _q, _attrs}, state), do: %{state | section: :fonts}
  defp event({:startElement, _uri, ~c"fills", _q, _attrs}, state), do: %{state | section: :fills}

  defp event({:startElement, _uri, ~c"cellXfs", _q, _attrs}, state),
    do: %{state | section: :cell_xfs}

  # cellStyleXfs holds <xf> elements too, and they are not what a cell points
  # at. Only the ones inside cellXfs are collected.
  defp event({:startElement, _uri, ~c"cellStyleXfs", _q, _attrs}, state),
    do: %{state | section: :style_xfs}

  # The differential formats conditional formatting uses hold <font> and <fill>
  # elements of their own. They are not in the lists a cell indexes into, so
  # counting them would send every style minted afterwards past the end.
  defp event({:startElement, _uri, ~c"dxfs", _q, _attrs}, state), do: %{state | section: :dxfs}

  defp event({:startElement, _uri, ~c"font", _q, _attrs}, %{section: :fonts} = state),
    do: %{state | font: %{}}

  defp event({:endElement, _uri, ~c"font", _q}, %{font: font} = state) when is_map(font) do
    %{state | fonts: [font | state.fonts], font: nil}
  end

  defp event({:startElement, _uri, ~c"fill", _q, _attrs}, %{section: :fills} = state),
    do: %{state | fill: %{}}

  defp event({:endElement, _uri, ~c"fill", _q}, %{fill: fill} = state) when is_map(fill) do
    %{state | fills: [fill | state.fills], fill: nil}
  end

  defp event({:startElement, _uri, ~c"b", _q, attrs}, %{font: font} = state) when is_map(font),
    do: put_font(state, :bold, Xml.flag(attrs, ~c"val"))

  defp event({:startElement, _uri, ~c"i", _q, attrs}, %{font: font} = state) when is_map(font),
    do: put_font(state, :italic, Xml.flag(attrs, ~c"val"))

  defp event({:startElement, _uri, ~c"u", _q, attrs}, %{font: font} = state) when is_map(font),
    do: put_font(state, :underline, Xml.flag(attrs, ~c"val"))

  defp event({:startElement, _uri, ~c"strike", _q, attrs}, %{font: font} = state)
       when is_map(font),
       do: put_font(state, :strikethrough, Xml.flag(attrs, ~c"val"))

  defp event({:startElement, _uri, ~c"sz", _q, attrs}, %{font: font} = state) when is_map(font) do
    case Xml.number(attrs, ~c"val") do
      size when is_number(size) and size > 0 -> put_font(state, :font_size, round(size))
      _ -> state
    end
  end

  defp event({:startElement, _uri, ~c"name", _q, attrs}, %{font: font} = state)
       when is_map(font) do
    case Xml.attr(attrs, ~c"val") do
      name when is_binary(name) and name != "" -> put_font(state, :font_family, name)
      _ -> state
    end
  end

  defp event({:startElement, _uri, ~c"color", _q, attrs}, %{font: font} = state)
       when is_map(font) do
    case Xml.color(attrs) do
      nil -> state
      color -> put_font(state, :color, color)
    end
  end

  # A pattern of "none" is no fill at all, whatever colour it names.
  defp event({:startElement, _uri, ~c"patternFill", _q, attrs}, %{fill: fill} = state)
       when is_map(fill) do
    %{state | fill: Map.put(fill, :pattern, Xml.attr(attrs, ~c"patternType"))}
  end

  defp event({:startElement, _uri, ~c"fgColor", _q, attrs}, %{fill: fill} = state)
       when is_map(fill) do
    case Xml.color(attrs) do
      nil -> state
      color -> %{state | fill: Map.put(fill, :background, color)}
    end
  end

  defp event({:startElement, _uri, ~c"xf", _q, attrs}, %{section: :cell_xfs} = state) do
    %{
      state
      | xf: %{
          number_format: Xml.int(attrs, ~c"numFmtId", 0),
          font: Xml.int(attrs, ~c"fontId", 0),
          fill: Xml.int(attrs, ~c"fillId", 0),
          alignment: %{}
        }
    }
  end

  defp event({:endElement, _uri, ~c"xf", _q}, %{section: :cell_xfs, xf: xf} = state)
       when is_map(xf) do
    %{state | xfs: [xf | state.xfs], xf: nil}
  end

  defp event({:startElement, _uri, ~c"alignment", _q, attrs}, %{xf: xf} = state)
       when is_map(xf) do
    alignment =
      %{}
      |> put_if(:horizontal, Map.get(@horizontal, Xml.attr(attrs, ~c"horizontal")))
      |> put_if(:vertical, Map.get(@vertical, Xml.attr(attrs, ~c"vertical")))
      |> put_if(:wrap, if(Xml.flag(attrs, ~c"wrapText", false), do: :wrap))

    %{state | xf: %{xf | alignment: alignment}}
  end

  defp event(_event, state), do: state

  defp put_font(%{font: font} = state, key, value), do: %{state | font: Map.put(font, key, value)}

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp assemble(state, source) do
    fonts = state.fonts |> Enum.reverse() |> index()
    fills = state.fills |> Enum.reverse() |> index()

    formats =
      state.xfs
      |> Enum.reverse()
      |> Enum.with_index()
      |> Map.new(fn {xf, index} ->
        {code, kind} = number_format(xf.number_format, state.number_formats)

        style =
          %{}
          |> Map.merge(font(fonts, xf.font))
          |> Map.merge(background(Map.get(fills, xf.fill, %{})))
          |> Map.merge(xf.alignment)
          |> put_if(:number_format, code)

        {index, %{style: style, kind: kind}}
      end)

    formats = if formats == %{}, do: new().formats, else: formats

    %__MODULE__{
      formats: formats,
      number_formats: state.number_formats,
      # Last index wins on a tie, so a style that two cellXfs describe the same
      # way is written back as the later one, which changes nothing about how
      # it looks, and keeps the earlier one free for the cells already using it.
      lookup: Map.new(formats, fn {index, entry} -> {entry.style, index} end),
      source: source,
      counts: %{
        fonts: max(map_size(fonts), 1),
        fills: max(map_size(fills), 2),
        xfs: map_size(formats)
      }
    }
  end

  defp index(list), do: list |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end)

  # Font 0 is the workbook's default, the one every plain cell points at, so
  # naming it on a cell says nothing about that cell. A style is how a cell
  # differs from a plain one, and a plain cell's style is `%{}`.
  defp font(_fonts, 0), do: %{}
  defp font(fonts, id), do: Map.get(fonts, id, %{})

  defp background(%{pattern: pattern, background: color}) when pattern not in [nil, "none"],
    do: %{background: color}

  defp background(_fill), do: %{}

  # The format code, and what it says the value is. A custom code is read; a
  # built-in one is looked up, because a file never writes those out. Either way
  # the code goes through the same `kind/1`, so an elapsed built-in (46,
  # `[h]:mm:ss`) is a number like an elapsed custom one, and 36 hours does not
  # come back as a 12-hour `Time` with the days thrown away.
  defp number_format(id, custom) do
    case Map.fetch(custom, id) do
      {:ok, code} ->
        {code, kind(code)}

      :error ->
        case Map.fetch(@builtin, id) do
          {:ok, code} -> {code, kind(code)}
          :error -> {Map.get(@builtin_numbers, id), nil}
        end
    end
  end

  @doc """
  What a number format code says a value is: a date, a time, both, or a plain
  number.

  `m` is the ambiguous one, month or minute depending on its company, so
  what decides is the unambiguous letters around it: `y` and `d` for a date,
  `h` and `s` for a time. Anything in quotes, escaped with a backslash, or in
  square brackets is a literal and says nothing, except `[h]`, `[m]` and `[s]`,
  which are elapsed-time fields and say a great deal.

      iex> alias Sheetshow.Xlsx.Styles
      iex> {Styles.kind("yyyy-mm-dd"), Styles.kind("h:mm:ss"), Styles.kind("m/d/yy h:mm")}
      {:date, :time, :datetime}
      iex> {Styles.kind("#,##0.00"), Styles.kind("General"), Styles.kind(nil)}
      {nil, nil, nil}
      iex> Styles.kind(~s(0.00" days"))
      nil
      iex> Styles.kind("[h]:mm:ss")
      nil
      iex> Styles.kind("h:mm:ss")
      :time
      iex> Styles.kind("[Red]#,##0;[Blue]-#,##0")
      nil
  """
  @spec kind(String.t() | nil) :: :date | :datetime | :time | nil
  def kind(nil), do: nil

  def kind(code) do
    section = code |> String.split(";") |> List.first()

    # An elapsed duration ([h], [m], [s]) is a count of hours, minutes or
    # seconds, not a moment: 36 hours is the number 1.5, and reading it as a
    # `Time` would throw the whole days away. It keeps its number and its format
    # instead, and reads back as the number it is. Anything a `Time` cannot hold
    # is not a `Time`.
    if Regex.match?(~r/\[[hms]+\]/i, section) do
      nil
    else
      bare = strip_literals(section)
      date? = String.match?(bare, ~r/[yd]/i)
      time? = String.match?(bare, ~r/[hs]/i)

      cond do
        date? and time? -> :datetime
        date? -> :date
        time? -> :time
        true -> nil
      end
    end
  end

  defp strip_literals(section) do
    section
    |> String.replace(~r/"[^"]*"/, "")
    |> String.replace(~r/\\./, "")
    |> String.replace(~r/\[[^\]]*\]/, "")
  end
end
