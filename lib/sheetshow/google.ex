defmodule Sheetshow.Google do
  @moduledoc """
  Ops as Google Sheets API requests: the body of one `spreadsheets.batchUpdate`.

  Google addresses sheets by a number, not a title, so encoding needs the ids
  the spreadsheet already has: `%{"Costs" => 0}`, which a backend reads off the
  metadata before it plans. A `Sheetshow.Op.AddSheet` picks an id for the sheet
  it creates, so the ops after it in the same plan can write to a tab that does
  not exist yet.

      iex> plan = Sheetshow.row(["Rent", 1000], sheet: "Costs") |> Sheetshow.plan!()
      iex> {:ok, body} = Sheetshow.Google.encode(plan, %{"Costs" => 0})
      iex> [%{updateCells: update}] = body.requests
      iex> update.start
      %{sheetId: 0, rowIndex: 0, columnIndex: 0}

  A batch is all-or-nothing at Google, so an op naming a sheet that is not there
  is an error here rather than a half-written spreadsheet, which is the answer
  `Sheetshow.Memory` gives too.

  Writing a cell replaces it: the field mask covers the value and the whole
  format, so a cell written without a style comes out with none, whatever was
  there before. That is what makes cells values rather than patches.
  """

  alias Sheetshow.{Cell, CellError, Coord, Error, Op, Result, Style, Value}

  @fields "userEnteredValue,userEnteredFormat"

  @horizontal %{left: "LEFT", center: "CENTER", right: "RIGHT"}
  @vertical %{top: "TOP", middle: "MIDDLE", bottom: "BOTTOM"}
  @wrap %{overflow: "OVERFLOW_CELL", clip: "CLIP", wrap: "WRAP"}

  @type sheet_ids :: %{String.t() => integer()}

  @doc """
  The scopes Sheetshow asks Google for when you name none, whichever kind of
  credential is asking.

      iex> Sheetshow.Google.default_scopes()
      ["https://www.googleapis.com/auth/spreadsheets"]

  `drive.file` is narrower but reaches only files the account itself created,
  so it cannot see a spreadsheet someone shared with the account.
  """
  @spec default_scopes() :: [String.t()]
  def default_scopes, do: ["https://www.googleapis.com/auth/spreadsheets"]

  # Sheet ids are non-negative 32-bit integers.
  @max_sheet_id 2_147_483_647

  @doc """
  A plan as a `spreadsheets.batchUpdate` body, given the sheet ids the
  spreadsheet already has.

      iex> {:error, %Sheetshow.Error{reason: :unknown_sheet}} =
      ...>   Sheetshow.Google.encode(Sheetshow.plan!([Sheetshow.Cell.new("Costs!A1", 1)]), %{})
  """
  @spec encode(Op.plan(), sheet_ids()) :: {:ok, map()} | {:error, Error.t()}
  def encode(plan, sheet_ids) when is_list(plan) and is_map(sheet_ids) do
    with {:ok, {_ids, requests}} <- Result.reduce(plan, {sheet_ids, []}, &encode_op/2) do
      {:ok, %{requests: Enum.reverse(requests)}}
    end
  end

  @doc "Same as `encode/2`, raising on failure."
  @spec encode!(Op.plan(), sheet_ids()) :: map()
  def encode!(plan, sheet_ids), do: plan |> encode(sheet_ids) |> Error.unwrap!()

  @doc """
  The id a new sheet will claim, given the ids already in use.

  It comes from the title, so it is the same every time, which keeps a plan
  readable in a test, and two writers adding *differently* named tabs at the
  same time ask for different ids. A title that is already taken is the one
  real conflict, and Google refuses that on its own; picking, say, the lowest
  free id instead would invent a second conflict between writers who were not
  in each other's way at all.

      iex> id = Sheetshow.Google.sheet_id("log")
      iex> Sheetshow.Google.sheet_id("log") == id
      true
      iex> Sheetshow.Google.sheet_id("log", %{"Costs" => id}) == id + 1
      true
  """
  @spec sheet_id(String.t(), sheet_ids()) :: non_neg_integer()
  def sheet_id(title, taken \\ %{}) when is_binary(title) do
    used = taken |> Map.values() |> MapSet.new()
    from = :erlang.phash2(title, @max_sheet_id)

    Enum.find(
      Stream.iterate(from, &rem(&1 + 1, @max_sheet_id)),
      &(not MapSet.member?(used, &1))
    )
  end

  @doc false
  # The field mask that makes a `spreadsheets.get` answer decodable: what the
  # cell holds, what Sheets made of it, and how it looks.
  @spec read_fields() :: String.t()
  def read_fields do
    "sheets(properties.title,data(startRow,startColumn,rowData.values(" <>
      "userEnteredValue,effectiveValue,formattedValue,userEnteredFormat," <>
      "effectiveFormat.numberFormat)))"
  end

  @doc false
  # The query that makes `spreadsheets.values.get` answer in the terms a schema
  # understands: what the cell holds rather than what it shows, and a date as
  # the serial number it really is.
  @spec value_options() :: keyword()
  def value_options do
    [valueRenderOption: "UNFORMATTED_VALUE", dateTimeRenderOption: "SERIAL_NUMBER"]
  end

  @doc """
  Rows of values from a `spreadsheets.values.get` answer.

  Google leaves trailing empty cells off the end of a row and trailing empty
  rows off the end of the answer, so the rows come back ragged; they are padded
  here to the width of the widest, and an empty cell is `nil`, which is the
  shape `Sheetshow.to_rows/1` gives.

      iex> Sheetshow.Google.decode_values(%{"values" => [["Rent", 1000], ["Food"]]})
      [["Rent", 1000], ["Food", nil]]

  What is lost against `decode/1` is what a cell *is*: this endpoint renders a
  formula's result and a formula's error as plain values, so `#DIV/0!` arrives
  as the string `"#DIV/0!"` and is indistinguishable from someone typing it.
  What is gained is the computed value and about a twelfth of the bytes,
  which is the trade a database read wants and a cell read does not.

      iex> Sheetshow.Google.decode_values(%{})
      []
  """
  @spec decode_values(map()) :: [[term()]]
  def decode_values(answer) when is_map(answer) do
    rows = Map.get(answer, "values", [])
    width = rows |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    for row <- rows do
      padded = row ++ List.duplicate(nil, width - length(row))

      Enum.map(padded, fn
        "" -> nil
        value -> value
      end)
    end
  end

  @doc false
  # One table per range from a `spreadsheets.values.batchGet` answer, in the
  # order the ranges were asked for.
  @spec decode_value_ranges(map()) :: [[[term()]]]
  def decode_value_ranges(answer) when is_map(answer) do
    for value_range <- Map.get(answer, "valueRanges", []), do: decode_values(value_range)
  end

  @doc """
  Cells from a `spreadsheets.get` answer.

  A cell's value is what was *entered*: a formula reads back as a formula, so
  cells you read are cells you can write again. What Sheets worked it out to
  goes in `meta`: `:formatted` is the text it displayed, `:effective` the value
  behind that text, which is where a `Sheetshow.CellError` turns up. Empty
  cells are not cells and are not returned.

      iex> answer = %{"sheets" => [%{
      ...>   "properties" => %{"title" => "Costs"},
      ...>   "data" => [%{"rowData" => [%{"values" => [
      ...>     %{"userEnteredValue" => %{"stringValue" => "Rent"}, "formattedValue" => "Rent"}
      ...>   ]}]}]
      ...> }]}
      iex> [cell] = Sheetshow.Google.decode(answer)
      iex> {Sheetshow.Coord.to_a1(cell.coord), cell.value, cell.meta}
      {"Costs!A1", "Rent", %{formatted: "Rent"}}

  Sheets keeps a date as a number and only its number format says so, so that
  is what the decoding leans on: a serial number formatted as a date comes back
  a `Date`, and one formatted as anything else stays a number.
  """
  @spec decode(map()) :: [Cell.t()]
  def decode(answer) when is_map(answer) do
    for sheet <- Map.get(answer, "sheets", []),
        title = get_in(sheet, ["properties", "title"]),
        block <- Map.get(sheet, "data", []),
        {row, down} <- Enum.with_index(Map.get(block, "rowData", [])),
        {data, across} <- Enum.with_index(Map.get(row, "values", [])),
        data != %{} do
      cell(
        data,
        Coord.new(
          Map.get(block, "startRow", 0) + down,
          Map.get(block, "startColumn", 0) + across,
          title
        )
      )
    end
  end

  defp encode_op(%Op.AddSheet{title: title}, {ids, requests}) do
    if Map.has_key?(ids, title) do
      {:error,
       Error.new(:duplicate_sheet, "the sheet #{inspect(title)} is already there", sheet: title)}
    else
      id = sheet_id(title, ids)
      request = %{addSheet: %{properties: %{sheetId: id, title: title}}}
      {:ok, {Map.put(ids, title, id), [request | requests]}}
    end
  end

  defp encode_op(%Op.DeleteSheet{title: title}, {ids, requests}) do
    with {:ok, id} <- sheet_id_of(title, ids) do
      {:ok, {Map.delete(ids, title), [%{deleteSheet: %{sheetId: id}} | requests]}}
    end
  end

  defp encode_op(op, {ids, requests}) do
    with {:ok, id} <- sheet_id_of(Op.sheet(op), ids) do
      {:ok, {ids, [request(op, id) | requests]}}
    end
  end

  defp sheet_id_of(title, ids) do
    case Map.fetch(ids, title) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, Error.unknown_sheet(title, ids |> Map.keys() |> Enum.sort())}
    end
  end

  defp request(%Op.PutCells{cells: cells} = op, id) do
    %{
      updateCells: %{
        start: %{
          sheetId: id,
          rowIndex: Op.PutCells.row(op),
          columnIndex: Op.PutCells.col(op)
        },
        rows: [%{values: Enum.map(cells, &cell_data/1)}],
        fields: @fields
      }
    }
  end

  defp request(%Op.AppendRows{cells: cells}, id) do
    %{appendCells: %{sheetId: id, rows: rows(cells), fields: @fields}}
  end

  defp request(%Op.DeleteRows{rows: first..last//1}, id) do
    %{
      deleteDimension: %{
        range: %{sheetId: id, dimension: "ROWS", startIndex: first, endIndex: last + 1}
      }
    }
  end

  defp request(%Op.SetDimensions{axis: axis, indexes: first..last//1, pixels: pixels}, id) do
    dimension = if axis == :cols, do: "COLUMNS", else: "ROWS"

    %{
      updateDimensionProperties: %{
        range: %{sheetId: id, dimension: dimension, startIndex: first, endIndex: last + 1},
        properties: %{pixelSize: pixels},
        fields: "pixelSize"
      }
    }
  end

  # Appended rows start at column 0 and run in order, so the gaps have to be
  # spelled out: an empty cell is an empty object, an empty row likewise.
  defp rows([]), do: []

  defp rows(cells) do
    by_row = Enum.group_by(cells, & &1.coord.row)
    last = cells |> Enum.map(& &1.coord.row) |> Enum.max()

    for row <- 0..last do
      case Map.get(by_row, row) do
        nil -> %{}
        row_cells -> %{values: row_values(row_cells)}
      end
    end
  end

  defp row_values(row_cells) do
    by_col = Map.new(row_cells, &{&1.coord.col, &1})
    last = row_cells |> Enum.map(& &1.coord.col) |> Enum.max()

    for col <- 0..last do
      case Map.get(by_col, col) do
        nil -> %{}
        cell -> cell_data(cell)
      end
    end
  end

  defp cell_data(%Cell{value: value, style: style}) do
    %{}
    |> put_present(:userEnteredValue, extended_value(value))
    |> put_present(:userEnteredFormat, format(style, value))
  end

  defp extended_value(nil), do: nil
  defp extended_value(value) when is_boolean(value), do: %{boolValue: value}
  defp extended_value(value) when is_number(value), do: %{numberValue: value}
  defp extended_value(value) when is_binary(value), do: %{stringValue: value}
  defp extended_value({:formula, formula}), do: %{formulaValue: formula}

  defp extended_value(%struct{} = value) when struct in [Date, NaiveDateTime, DateTime, Time],
    do: %{numberValue: Value.to_serial(value)}

  defp format(style, value) do
    %{}
    |> put_present(:textFormat, text_format(style))
    |> put_value(:backgroundColorStyle, style[:background], &color_style/1)
    |> put_value(:horizontalAlignment, style[:horizontal], &Map.fetch!(@horizontal, &1))
    |> put_value(:verticalAlignment, style[:vertical], &Map.fetch!(@vertical, &1))
    |> put_value(:wrapStrategy, style[:wrap], &Map.fetch!(@wrap, &1))
    |> put_value(:numberFormat, style[:number_format], &number_format(&1, value))
  end

  defp text_format(style) do
    %{}
    |> put_value(:bold, style[:bold], & &1)
    |> put_value(:italic, style[:italic], & &1)
    |> put_value(:underline, style[:underline], & &1)
    |> put_value(:strikethrough, style[:strikethrough], & &1)
    |> put_value(:fontSize, style[:font_size], & &1)
    |> put_value(:fontFamily, style[:font_family], & &1)
    |> put_value(:foregroundColorStyle, style[:color], &color_style/1)
  end

  # The pattern is the user's; the type comes from what the cell holds, because
  # Sheets keeps dates as numbers and only the type says which kind of number.
  defp number_format(pattern, value) do
    type =
      case Value.kind(value) do
        :date -> "DATE"
        :datetime -> "DATE_TIME"
        :time -> "TIME"
        _other -> "NUMBER"
      end

    %{type: type, pattern: pattern}
  end

  defp color_style(hex) do
    {red, green, blue} = Style.hex_to_rgb(hex)
    %{rgbColor: %{red: red / 255, green: green / 255, blue: blue / 255}}
  end

  defp put_value(map, _key, nil, _fun), do: map
  defp put_value(map, key, value, fun), do: Map.put(map, key, fun.(value))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, empty) when map_size(empty) == 0, do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp cell(data, coord) do
    kind = data |> get_in(["effectiveFormat", "numberFormat", "type"]) |> temporal()

    meta =
      %{}
      |> put_value(:formatted, data["formattedValue"], & &1)
      |> put_value(:effective, decode_value(data["effectiveValue"], kind), & &1)

    %Cell{
      coord: coord,
      value: decode_value(data["userEnteredValue"], kind),
      style: decode_style(Map.get(data, "userEnteredFormat", %{})),
      meta: meta
    }
  end

  defp temporal("DATE"), do: :date
  defp temporal("DATE_TIME"), do: :datetime
  defp temporal("TIME"), do: :time
  defp temporal(_other), do: nil

  defp decode_value(nil, _kind), do: nil
  defp decode_value(%{"numberValue" => number}, nil), do: number
  defp decode_value(%{"numberValue" => number}, kind), do: Value.from_serial(number, kind)
  defp decode_value(%{"stringValue" => string}, _kind), do: string
  defp decode_value(%{"boolValue" => boolean}, _kind), do: boolean
  defp decode_value(%{"formulaValue" => formula}, _kind), do: {:formula, formula}

  defp decode_value(%{"errorValue" => error}, _kind) do
    CellError.new(Map.get(error, "type", "ERROR"), error["message"])
  end

  defp decode_value(_other, _kind), do: nil

  defp decode_style(format) do
    text = Map.get(format, "textFormat", %{})

    %{}
    |> put_value(:bold, text["bold"], & &1)
    |> put_value(:italic, text["italic"], & &1)
    |> put_value(:underline, text["underline"], & &1)
    |> put_value(:strikethrough, text["strikethrough"], & &1)
    |> put_value(:font_size, text["fontSize"], & &1)
    |> put_value(:font_family, text["fontFamily"], & &1)
    |> put_value(:color, hex(text["foregroundColorStyle"]), & &1)
    |> put_value(:background, hex(format["backgroundColorStyle"]), & &1)
    |> put_value(:horizontal, name(@horizontal, format["horizontalAlignment"]), & &1)
    |> put_value(:vertical, name(@vertical, format["verticalAlignment"]), & &1)
    |> put_value(:wrap, name(@wrap, format["wrapStrategy"]), & &1)
    |> put_value(:number_format, get_in(format, ["numberFormat", "pattern"]), & &1)
  end

  # Google leaves out a colour component that is zero, so each one defaults.
  defp hex(%{"rgbColor" => rgb}) do
    Style.rgb_to_hex({channel(rgb["red"]), channel(rgb["green"]), channel(rgb["blue"])})
  end

  defp hex(_other), do: nil

  defp channel(nil), do: 0
  defp channel(fraction), do: round(fraction * 255)

  defp name(mapping, wire) do
    Enum.find_value(mapping, fn {name, value} -> if value == wire, do: name end)
  end
end
