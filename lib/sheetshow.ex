defmodule Sheetshow do
  @moduledoc """
  Google Sheets from Elixir, as values.

  A spreadsheet is a list of `Sheetshow.Cell` structs in no particular order.
  The functions here build such lists from rows, columns, tables and records
  and lay them out next to and below each other, and `plan/2` turns the result
  into the ops a backend carries out.

      iex> import Sheetshow
      iex> costs = [%{item: "Rent", cost: 1000}, %{item: "Food", cost: 400}]
      iex> cells =
      ...>   stack([
      ...>     row(["Item", "Cost"], style: %{bold: true}),
      ...>     records(costs, [:item, :cost])
      ...>   ])
      ...>   |> put_sheet("Costs")
      iex> to_rows(cells)
      [["Item", "Cost"], ["Rent", 1000], ["Food", 400]]
      iex> Sheetshow.Range.bounding(cells) |> Sheetshow.Range.to_a1()
      "Costs!A1:B3"

  Layout works on row and column numbers only. A group keeps its own internal
  offsets when concatenated, so a group whose first cell sits at row 2 lands
  two rows below the group above it.

  Sheetshow defines no GenServer, supervisor or application callback module, and
  no macros. Credentials, tokens and caches are values you pass in, and so are
  retries. A plan is one request however many ops it holds, which is what keeps
  you inside Google's quota; see
  [What Sheetshow Can Promise](guides/guarantees.md) for that, and for what a
  write can and cannot guarantee.
  """

  alias Sheetshow.{Cell, Coord, Error, Op, Planner, Range, Result, Style, Workbook}

  @type cells :: [Cell.t()]
  @type layout_opts :: [
          row: non_neg_integer(),
          col: non_neg_integer(),
          sheet: String.t(),
          style: Style.t()
        ]
  @type plan_opts :: [sheet: String.t(), existing_sheets: [String.t()]]

  @doc """
  Turns cells into a plan: the ops that write them, in the order they are to be
  carried out.

  Options:

    * `:sheet`, the sheet for cells that name none. Without it, a cell that
      names no sheet is an error, because an op has to say where it writes.
    * `:existing_sheets`, the sheets the spreadsheet already has. Every other
      sheet the cells name gets a `Sheetshow.Op.AddSheet` at the front of the
      plan. Leave it out and the plan assumes the sheets are all there.

  Cells are checked before anything else, so a plan is only ever made of cells
  that can be written. Scattered cells become one `Sheetshow.Op.PutCells` per
  run, so a write never clears a neighbour; a date, time or datetime with no
  `:number_format` of its own gets the format that makes it readable; and the
  `:col_width` and `:row_height` styles are lifted out into
  `Sheetshow.Op.SetDimensions`. Two cells at one coordinate are a late edit of
  the same cell: the last one wins.

      iex> cells = [Sheetshow.Cell.new("A1", 1), Sheetshow.Cell.new("C1", 3)]
      iex> {:ok, plan} = Sheetshow.plan(cells, sheet: "Costs")
      iex> Enum.map(plan, &Sheetshow.Range.to_a1(Sheetshow.Op.PutCells.range(&1)))
      ["Costs!A1", "Costs!C1"]

      iex> {:error, %Sheetshow.Error{reason: :missing_sheet}} =
      ...>   Sheetshow.plan(Sheetshow.row([1]))
  """
  @spec plan(cells(), plan_opts()) :: {:ok, Op.plan()} | {:error, Error.t()}
  def plan(cells, opts \\ []), do: Planner.plan(cells, opts)

  @doc """
  Same as `plan/2`, raising on failure.

      iex> Sheetshow.row([1, 2], sheet: "Costs") |> Sheetshow.plan!() |> length()
      1
  """
  @spec plan!(cells(), plan_opts()) :: Op.plan()
  def plan!(cells, opts \\ []), do: cells |> plan(opts) |> Error.unwrap!()

  @doc """
  Makes a workbook ready to use and learns the sheets it has. For Google that
  is a token and one metadata request, and it authenticates only when there is
  no good token already, so calling it again is cheap in everything but the
  request. For a backend with nothing to reach it is free.

      workbook = Sheetshow.Workbook.google(id, credentials: Sheetshow.ServiceAccount.from_file!(path))
      {:ok, workbook} = Sheetshow.connect(workbook)
      workbook.sheets
      %{"Sheet1" => 0}

      iex> {:ok, workbook} = Sheetshow.Workbook.memory(["Costs"]) |> Sheetshow.connect()
      iex> Sheetshow.Workbook.titles(workbook)
      ["Costs"]
  """
  @spec connect(Workbook.t()) :: {:ok, Workbook.t()} | {:error, Error.t()}
  def connect(%Workbook{backend: backend} = workbook), do: backend.connect(workbook)

  @doc """
  Trades the workbook's credentials for an access token. When and whether to do
  this again is yours to decide: `Sheetshow.Client.ready?/2` answers it.

  A backend with no credentials to trade, which means the in-memory one and
  every file backend, answers `{:error, %Sheetshow.Error{reason: :unsupported}}`.
  """
  @spec authenticate(Workbook.t()) :: {:ok, Workbook.t()} | {:error, Error.t()}
  def authenticate(%Workbook{backend: backend} = workbook) do
    if Code.ensure_loaded?(backend) and function_exported?(backend, :authenticate, 1) do
      backend.authenticate(workbook)
    else
      {:error,
       Error.new(:unsupported, "#{inspect(backend)} has no credentials to trade",
         backend: backend
       )}
    end
  end

  @doc """
  Asks the spreadsheet which sheets it has, and puts them on the workbook.
  """
  @spec fetch_sheets(Workbook.t()) :: {:ok, Workbook.t()} | {:error, Error.t()}
  def fetch_sheets(%Workbook{backend: backend} = workbook), do: backend.fetch_sheets(workbook)

  @doc """
  Carries out a plan and gives back the workbook. At Google it is one
  `spreadsheets.batchUpdate`, applied whole or not at all, so there is no half
  written spreadsheet to clean up; `Sheetshow.Backend.supports?/2` says whether
  a given backend promises that much.

  The workbook comes back knowing about any sheets the plan created, so a
  second plan against it needs no fresh metadata. An empty plan asks the
  backend nothing.

      {:ok, workbook} = Sheetshow.connect(workbook)
      cells = Sheetshow.row(["Rent", 1000], sheet: "Costs")
      {:ok, workbook} =
        cells
        |> Sheetshow.plan!(existing_sheets: Map.keys(workbook.sheets))
        |> Sheetshow.run(workbook)

      iex> workbook = Sheetshow.Workbook.memory()
      iex> cells = Sheetshow.row(["Rent", 1000], sheet: "Costs")
      iex> {:ok, workbook} = cells |> Sheetshow.plan!(existing_sheets: []) |> Sheetshow.run(workbook)
      iex> Sheetshow.read_cells!("Costs!A1:B1", workbook) |> Sheetshow.to_rows()
      [["Rent", 1000]]
  """
  @spec run(Op.plan(), Workbook.t()) :: {:ok, Workbook.t()} | {:error, Error.t()}
  def run(plan, %Workbook{backend: backend} = workbook), do: backend.run(plan, workbook)

  @doc """
  The cells in a range, in reading order, with empty cells left out.

  A cell's value is what was entered, so a formula reads back as a formula and
  the cells you read are cells you can write again. What Sheets worked it out
  to is in `meta`, under `:formatted` and `:effective`. The range needs a
  sheet, because a spreadsheet has more than one.

      {:ok, cells} = Sheetshow.read_cells("Costs!A1:C10", workbook)
      Sheetshow.to_rows(cells)
      [["Item", "Cost"], ["Rent", 1000]]
  """
  @spec read_cells(Range.t() | String.t(), Workbook.t()) :: {:ok, cells()} | {:error, Error.t()}
  def read_cells(range, %Workbook{backend: backend} = workbook) do
    with {:ok, range} <- range(range), do: backend.read_cells(range, workbook)
  end

  @doc "Same as `read_cells/2`, raising on failure."
  @spec read_cells!(Range.t() | String.t(), Workbook.t()) :: cells()
  def read_cells!(range, workbook), do: range |> read_cells(workbook) |> Error.unwrap!()

  @doc """
  The values in a range, as rows: what the cells work out to, rather than what
  they hold.

  This is the other read, and the one a stored table wants. `read_cells/2` asks for
  cells and gets back everything about them: what was entered, what Sheets
  made of it, and the format, which is the only thing that says a number is a
  date. `read_rows/2` asks the values endpoint for the computed value alone,
  which is about a twelfth of the bytes, and leaves the question of what a
  number means to a `Sheetshow.Schema` that already knows. A formula arrives as
  its result here, and a formula's error as the text of it, so cells you read
  this way are not cells you can write back.

  Rows are padded to the width of the widest and an empty cell is `nil`, as in
  `to_rows/1`. The range needs a sheet.

      {:ok, rows} = Sheetshow.read_rows("Costs!A1:C10", workbook)
      [["Item", "Cost"], ["Rent", 1000]]

  Given a list of ranges it asks for all of them at once, and answers with one
  table per range, in the order you gave them. Two reads that would otherwise be
  two round trips, a header and the rows below a cursor, say, become one.

      {:ok, [header, rows]} = Sheetshow.read_rows(["log!A1:C1", "log!A900:C"], workbook)
  """
  @spec read_rows(Range.t() | String.t() | [Range.t() | String.t()], Workbook.t()) ::
          {:ok, [[term()]] | [[[term()]]]} | {:error, Error.t()}
  def read_rows(ranges, workbook)

  def read_rows([], %Workbook{}), do: {:ok, []}

  def read_rows(ranges, %Workbook{backend: backend} = workbook) when is_list(ranges) do
    with {:ok, ranges} <- Result.map(ranges, &range/1),
         do: backend.read_rows_batch(ranges, workbook)
  end

  def read_rows(range, %Workbook{backend: backend} = workbook) do
    with {:ok, range} <- range(range), do: backend.read_rows(range, workbook)
  end

  @doc "Same as `read_rows/2`, raising on failure."
  @spec read_rows!(Range.t() | String.t() | [Range.t() | String.t()], Workbook.t()) ::
          [[term()]] | [[[term()]]]
  def read_rows!(ranges, workbook), do: ranges |> read_rows(workbook) |> Error.unwrap!()

  # A backend is only ever asked about a range that names its sheet.
  defp range(%Range{} = range), do: Range.on_sheet(range)
  defp range(a1) when is_binary(a1), do: with({:ok, range} <- Range.from_a1(a1), do: range(range))

  @doc """
  One row of cells from a list of values, left to right.

  Options: `:row` and `:col` place the first cell (default `0`, `0`); `:sheet`
  and `:style` apply to every cell.

      iex> Sheetshow.row(["a", "b"], row: 1, style: %{bold: true}) |> Sheetshow.to_rows()
      [["a", "b"]]
  """
  @spec row([Sheetshow.Value.t()], layout_opts()) :: cells()
  def row(values, opts \\ []) when is_list(values) do
    {row, col, sheet, style} = layout(opts)

    for {value, i} <- Enum.with_index(values),
        do: Cell.new(Coord.new(row, col + i, sheet), value, style)
  end

  @doc """
  One column of cells from a list of values, top to bottom. Same options as
  `row/2`.

      iex> Sheetshow.col([1, 2, 3]) |> Sheetshow.max_row()
      2
  """
  @spec col([Sheetshow.Value.t()], layout_opts()) :: cells()
  def col(values, opts \\ []) when is_list(values) do
    {row, col, sheet, style} = layout(opts)

    for {value, i} <- Enum.with_index(values),
        do: Cell.new(Coord.new(row + i, col, sheet), value, style)
  end

  @doc """
  Cells from rows of values. Rows may be ragged. Same options as
  `row/2`.

      iex> Sheetshow.rows([[1, 2], [3]]) |> Enum.map(&Sheetshow.Coord.to_a1(&1.coord))
      ["A1", "B1", "A2"]
  """
  @spec rows([[Sheetshow.Value.t()]], layout_opts()) :: cells()
  def rows(rows, opts \\ []) when is_list(rows) do
    {row, col, sheet, style} = layout(opts)

    for {values, i} <- Enum.with_index(rows),
        {value, j} <- Enum.with_index(values),
        do: Cell.new(Coord.new(row + i, col + j, sheet), value, style)
  end

  @doc """
  One row of cells per record (a map or struct), one column per key, in key
  order; a missing key is an empty cell.

  Same options as `row/2`, plus `:header`: `true` puts the keys' names
  in a first row, a list of strings puts those labels there.

      iex> [%{item: "Rent", cost: 1000}, %{item: "Food"}]
      ...> |> Sheetshow.records([:item, :cost], header: true)
      ...> |> Sheetshow.to_rows()
      [["item", "cost"], ["Rent", 1000], ["Food", nil]]
  """
  @spec records([map()], [term()], keyword()) :: cells()
  def records(records, keys, opts \\ []) when is_list(records) and is_list(keys) do
    header =
      case Keyword.get(opts, :header) do
        nil -> []
        true -> [Enum.map(keys, &to_string/1)]
        labels when is_list(labels) -> [labels]
      end

    body = for record <- records, do: Enum.map(keys, &Map.get(record, &1))
    rows(header ++ body, Keyword.delete(opts, :header))
  end

  @doc """
  Values back from cells, as rows relative to their bounding range; gaps are
  `nil`. When two cells share a coordinate the later one wins. Cells must share
  a sheet. No cells is no rows, which is what a read of an empty range gives.

      iex> Sheetshow.to_rows([Sheetshow.Cell.new("B2", 1), Sheetshow.Cell.new("C3", 2)])
      [[1, nil], [nil, 2]]
      iex> Sheetshow.to_rows([])
      []
  """
  @spec to_rows(cells()) :: [[Sheetshow.Value.t()]]
  def to_rows([]), do: []

  def to_rows([_ | _] = cells) do
    %Range{start_row: r1, start_col: c1, end_row: r2, end_col: c2} = Range.bounding(cells)

    values =
      Map.new(cells, fn %Cell{coord: coord, value: value} -> {{coord.row, coord.col}, value} end)

    for r <- r1..r2, do: for(c <- c1..c2, do: Map.get(values, {r, c}))
  end

  @doc """
  Stacks groups of cells, each starting on the row after the previous group's
  last one. Empty groups take no room.

      iex> Sheetshow.stack([Sheetshow.row([1, 2]), Sheetshow.row([3, 4])])
      ...> |> Sheetshow.to_rows()
      [[1, 2], [3, 4]]
  """
  @spec stack([cells()]) :: cells()
  def stack(groups) when is_list(groups) do
    groups
    |> Enum.reduce([], fn group, acc ->
      offset = if acc == [], do: 0, else: max_row(acc) + 1
      Enum.reverse(shift(group, offset, 0), acc)
    end)
    |> Enum.reverse()
  end

  @doc "Same as `stack([above, below])`, for pipelines."
  @spec stack(cells(), cells()) :: cells()
  def stack(above, below), do: stack([above, below])

  @doc """
  Places groups of cells side by side, each starting on the column after the
  previous group's last one. Empty groups take no room.

      iex> Sheetshow.beside([Sheetshow.col([1, 2]), Sheetshow.col([3, 4])])
      ...> |> Sheetshow.to_rows()
      [[1, 3], [2, 4]]
  """
  @spec beside([cells()]) :: cells()
  def beside(groups) when is_list(groups) do
    groups
    |> Enum.reduce([], fn group, acc ->
      offset = if acc == [], do: 0, else: max_col(acc) + 1
      Enum.reverse(shift(group, 0, offset), acc)
    end)
    |> Enum.reverse()
  end

  @doc "Same as `beside([left, right])`, for pipelines."
  @spec beside(cells(), cells()) :: cells()
  def beside(left, right), do: beside([left, right])

  @doc """
  Adds `n` empty rows below the cells, so the next `stack/1` leaves a
  gap. The room is held by one empty cell in the first column of the last
  padded row.

      iex> Sheetshow.row([1]) |> Sheetshow.pad_below(2) |> Sheetshow.max_row()
      2
  """
  @spec pad_below(cells(), pos_integer()) :: cells()
  def pad_below(cells, n \\ 1) when is_integer(n) and n > 0 do
    stack([cells, [Cell.new(Coord.new(n - 1, 0, sheet_of(cells)))]])
  end

  @doc """
  Adds `n` empty columns to the right of the cells; see `pad_below/2`.

      iex> Sheetshow.col([1]) |> Sheetshow.pad_right() |> Sheetshow.max_col()
      1
  """
  @spec pad_right(cells(), pos_integer()) :: cells()
  def pad_right(cells, n \\ 1) when is_integer(n) and n > 0 do
    beside([cells, [Cell.new(Coord.new(0, n - 1, sheet_of(cells)))]])
  end

  @doc """
  Moves every cell by `rows` down and `cols` right; see `Sheetshow.Cell.shift/3`.

      iex> Sheetshow.row([1]) |> Sheetshow.shift(2, 3) |> hd() |> Map.fetch!(:coord) |> Sheetshow.Coord.to_a1()
      "D3"
  """
  @spec shift(cells(), integer(), integer()) :: cells()
  def shift(cells, rows, cols) when is_list(cells),
    do: Enum.map(cells, &Cell.shift(&1, rows, cols))

  @doc """
  Puts every cell on a sheet.

      iex> Sheetshow.row([1]) |> Sheetshow.put_sheet("Costs") |> hd() |> Map.fetch!(:coord)
      %Sheetshow.Coord{row: 0, col: 0, sheet: "Costs"}
  """
  @spec put_sheet(cells(), String.t() | nil) :: cells()
  def put_sheet(cells, sheet) when is_list(cells), do: Enum.map(cells, &Cell.put_sheet(&1, sheet))

  @doc """
  Merges a style into every cell's; see `Sheetshow.Cell.put_style/2`.

      iex> Sheetshow.row([1], style: %{bold: true}) |> Sheetshow.put_style(%{italic: true}) |> hd() |> Map.fetch!(:style)
      %{bold: true, italic: true}
  """
  @spec put_style(cells(), Style.t()) :: cells()
  def put_style(cells, style) when is_list(cells), do: Enum.map(cells, &Cell.put_style(&1, style))

  @doc """
  The highest row any cell sits on, or `nil` for no cells.

      iex> Sheetshow.max_row([])
      nil
  """
  @spec max_row(cells()) :: non_neg_integer() | nil
  def max_row(cells) when is_list(cells),
    do: cells |> Enum.map(& &1.coord.row) |> Enum.max(fn -> nil end)

  @doc """
  The highest column any cell sits on, or `nil` for no cells.

      iex> Sheetshow.max_col(Sheetshow.row([1, 2, 3]))
      2
  """
  @spec max_col(cells()) :: non_neg_integer() | nil
  def max_col(cells) when is_list(cells),
    do: cells |> Enum.map(& &1.coord.col) |> Enum.max(fn -> nil end)

  defp layout(opts) do
    {Keyword.get(opts, :row, 0), Keyword.get(opts, :col, 0), Keyword.get(opts, :sheet),
     Keyword.get(opts, :style, %{})}
  end

  defp sheet_of([%Cell{coord: %Coord{sheet: sheet}} | _]), do: sheet
  defp sheet_of([]), do: nil
end
