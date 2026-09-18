defmodule Sheetshow.Log do
  @moduledoc """
  An append-only tab, and the first of the two ways to keep data on a sheet.

  A log's rows are events, each carrying an id its writer made. Nothing is ever
  overwritten: an update is the same id appended again, a delete is the same id
  appended with the `deleted` flag, and the state of the log is the fold over
  the rows: the last one per id wins, and tombstoned ids drop out.

      iex> alias Sheetshow.{Log, Workbook}
      iex> log = Log.new("expenses", item: :string, cost: :decimal)
      iex> rent = Log.Event.new(%{item: "Rent", cost: "1000.00"}, id: "a")
      iex> food = Log.Event.new(%{item: "Food", cost: "400.00"}, id: "b")
      iex> {:ok, workbook} = Sheetshow.run(Log.create(log) ++ Log.plan!([rent, food], log), Workbook.memory())
      iex> later = [Log.Event.put(rent, %{cost: "1100.00"}), Log.Event.delete(food)]
      iex> {:ok, workbook} = Sheetshow.run(Log.plan!(later, log), workbook)
      iex> Log.read!(log, workbook) |> Log.fold() |> Enum.map(& &1.record)
      [%{item: "Rent", cost: "1100.00"}]

  That one rule does three jobs. It makes updates and deletes out of the only
  write Google resolves for you, since `appendCells` lands below the last row
  with data at the moment it is applied, so two processes appending to one tab
  cannot overwrite each other, and no compare-and-swap is needed. And it makes
  a write safe to retry: a batch that landed but answered with a transport
  error can be sent again, because the duplicate ids fold away. Retry a failed
  batch *before* you write anything newer, though, because a stale retry that
  lands late is a stale last row.

  **That is Google's promise, not a file's.** A file is rewritten whole, so two
  writers appending to one can lose each other's rows unless the store can
  refuse a clobbering write, in which case the loser gets
  `%Sheetshow.Error{reason: :conflict}` with nothing written, and running the
  *same plan again* is safe, because the ids in it fold away against themselves.
  [What Sheetshow Can Promise](guides/guarantees.md) has the whole of it.

  The tab is laid out for a person to read. Row 0 is the header (`id`,
  `deleted`, then the schema's columns in order), and `deleted` is left blank
  on a live row, so a reader sees a flag only where something was taken out.
  Columns are found by header name when reading, but appends are positional, so
  **the schema's order is the tab's column order**: add columns at the end and
  re-put `header/2`, and leave the ones already there where they are. Anything
  further right is a person's own business and is not touched.

  Reading is lenient. A cell someone typed that will not cast leaves that field
  `nil` and an entry in the event's `errors`, so a typo costs you a field
  rather than the read; `decode/3` with `strict: true` refuses such a read
  instead.
  """

  alias Sheetshow.{A1, Cell, Coord, Error, Op, Range, Records, Result, Schema, Workbook}
  alias Sheetshow.Log.Event

  @enforce_keys [:sheet, :schema]
  defstruct [:sheet, :schema]

  @type t :: %__MODULE__{sheet: String.t(), schema: Schema.t()}

  @id "id"
  @decode_options [:header, :row, :strict]
  @read_options [:after, :strict]

  @doc """
  A log on a tab, with the columns its rows have. Raises `ArgumentError` on a
  schema `Sheetshow.Schema.validate/1` refuses, and on one that names an `id` or
  `deleted` column, which the model keeps for itself.

      iex> Sheetshow.Log.new("expenses", item: :string, cost: :decimal).sheet
      "expenses"
  """
  @spec new(String.t(), Schema.t()) :: t()
  def new(sheet, schema) when is_binary(sheet) do
    case Records.validate_schema(schema) do
      :ok -> %__MODULE__{sheet: sheet, schema: schema}
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  @doc """
  The tab's columns, left to right.

      iex> Sheetshow.Log.new("expenses", item: :string) |> Sheetshow.Log.columns()
      ["id", "deleted", "item"]
  """
  @spec columns(t()) :: [String.t()]
  def columns(%__MODULE__{schema: schema}), do: Records.columns(schema)

  @doc """
  The header as cells, bold unless you say otherwise. Write these again after
  adding a column to the end of the schema.

      iex> Sheetshow.Log.new("expenses", item: :string)
      ...> |> Sheetshow.Log.header()
      ...> |> Sheetshow.to_rows()
      [["id", "deleted", "item"]]
  """
  @spec header(t(), Sheetshow.Style.t()) :: [Cell.t()]
  def header(%__MODULE__{} = log, style \\ %{bold: true}), do: Records.header(log, style)

  @doc """
  Cells for a second tab that shows the log as it stands, for a person to look
  at: one live row per id, newest content, tombstones gone.

  It is a single formula, so Sheets keeps it current as the log grows, and
  nothing has to be rewritten when rows are appended. The `deleted` column is
  left out, since every row on this tab is one that was not.

      log |> Sheetshow.Log.view("expenses now") |> Sheetshow.plan!(existing_sheets: [])

  The formula is what `fold/1` does, said in Sheets: drop the blank rows, put
  the log newest-first, keep one row per id, drop the deleted ones, and order
  what is left by id.

  **The same rows, in id order.** `fold/1` keeps the order the ids first
  appeared in; this tab can only sort by what is on it, which is the id. Those
  agree when your ids increase in the order you make them, which a
  `Sheetshow.ULID` does down to the microsecond, so a batch of events made in
  one go reads back here in the order it was made. Ids of your own need to sort
  the same way if the order on this tab has to mean something.

  **Said in Sheets, and only there.** It turns on `SORTN`, which Excel has no
  counterpart for, so a view tab written into an `.xlsx` shows `#NAME?` when
  somebody opens it. Nothing is harmed, since a formula that does not resolve
  is a cell that does not resolve, but the tab is pointless there, and `fold/1`
  is what a file-backed log uses instead.

      iex> Sheetshow.Log.new("log", item: :string)
      ...> |> Sheetshow.Log.view("now")
      ...> |> Sheetshow.to_rows()
      ...> |> hd()
      ["id", "item"]
  """
  @spec view(t(), String.t()) :: [Cell.t()]
  def view(%__MODULE__{} = log, sheet) when is_binary(sheet) do
    header = [@id | Schema.columns(log.schema)]

    Sheetshow.row(header, sheet: sheet, style: %{bold: true}) ++
      [Cell.new(Coord.new(1, 0, sheet), {:formula, formula(log)})]
  end

  defp formula(log) do
    source = "#{A1.quote_sheet(log.sheet)}!A2:#{A1.col_to_letters(last_col(log))}"
    # Every column but the second, which is `deleted`.
    kept = [1 | Enum.to_list(3..(last_col(log) + 1)//1)] |> Enum.join(", ")

    "=IFERROR(LET(" <>
      "src, FILTER(#{source}, INDEX(#{source}, , 1) <> \"\"), " <>
      "latest, SORTN(SORT(src, SEQUENCE(ROWS(src)), FALSE), 9^9, 2, 1, TRUE), " <>
      "CHOOSECOLS(SORT(FILTER(latest, INDEX(latest, , 2) <> TRUE), 1, TRUE), #{kept})" <>
      "), \"\")"
  end

  defp last_col(%__MODULE__{} = log), do: length(columns(log)) - 1

  @doc """
  The plan that makes the tab and writes its header. Fails at the backend if
  the tab is already there, which is what you want from something called
  `create`.

      iex> Sheetshow.Log.new("expenses", item: :string) |> Sheetshow.Log.create() |> Enum.map(&Sheetshow.Op.sheet/1)
      ["expenses", "expenses"]
  """
  @spec create(t()) :: Op.plan()
  def create(%__MODULE__{} = log), do: Sheetshow.plan!(header(log), existing_sheets: [])

  @doc """
  The plan that appends events, as one `Sheetshow.Op.AppendRows`, so a batch of
  them is atomic and lands below whatever else arrived in the meantime.

  Strict, as writing always is: a record whose values do not fit the schema, or
  which names a column the schema does not have, is an error here rather than a
  surprise in the sheet. An empty list is an empty plan.

      iex> log = Sheetshow.Log.new("expenses", item: :string)
      iex> {:ok, [op]} = Sheetshow.Log.plan([Sheetshow.Log.Event.new(%{item: "Rent"})], log)
      iex> Sheetshow.Op.AppendRows.height(op)
      1

      iex> log = Sheetshow.Log.new("expenses", cost: :integer)
      iex> {:error, %Sheetshow.Error{reason: :invalid_record}} =
      ...>   Sheetshow.Log.plan([Sheetshow.Log.Event.new(%{cost: "free"})], log)
  """
  @spec plan([Event.t()], t()) :: {:ok, Op.plan()} | {:error, Error.t()}
  def plan([], %__MODULE__{}), do: {:ok, []}

  def plan(events, %__MODULE__{} = log) when is_list(events) do
    with {:ok, cells} <- rows(events, log) do
      {:ok, [Op.AppendRows.new(cells, log.sheet)]}
    end
  end

  @doc """
  Same as `plan/2`, raising on failure.

      iex> log = Sheetshow.Log.new("expenses", item: :string)
      iex> Sheetshow.Log.plan!([], log)
      []
  """
  @spec plan!([Event.t()], t()) :: Op.plan()
  def plan!(events, %__MODULE__{} = log), do: events |> plan(log) |> Error.unwrap!()

  defp rows(events, log) do
    with {:ok, rows} <-
           events
           |> Enum.with_index()
           |> Result.map(fn {event, row} -> row_cells(event, row, log.schema) end) do
      {:ok, List.flatten(rows)}
    end
  end

  defp row_cells(%Event{id: id} = event, _row, _schema) when not is_binary(id) do
    {:error,
     Error.new(
       :missing_id,
       "an event needs an id to be written: #{inspect(event)}",
       event: event
     )}
  end

  defp row_cells(%Event{} = event, row, schema) do
    with {:ok, values} <- encode(event, schema) do
      flag = if event.deleted, do: [cell(row, 1, true)], else: []

      columns =
        for {value, index} <- Enum.with_index(values), not is_nil(value) do
          cell(row, index + 2, value)
        end

      {:ok, [cell(row, 0, event.id) | flag] ++ columns}
    end
  end

  defp encode(%Event{record: record} = event, schema) do
    case Schema.encode(record, schema) do
      {:ok, values} -> {:ok, values}
      {:error, error} -> {:error, %{error | details: Map.put(error.details, :event, event)}}
    end
  end

  defp cell(row, col, value), do: Records.cell(row, col, value)

  @doc """
  Events from the tab's values: rows of cell values, as `Sheetshow.read_cells/2` or
  `Sheetshow.to_rows/1` gives them.

  Options:

    * `:header`, the header row, when `rows` holds only data. Without it the
      first row of `rows` is the header.
    * `:row`, the sheet row the first given row sits on, so events know where
      they are. Defaults to `0` with a header in `rows`, `1` without.
    * `:strict`, to refuse the read when any cell would not cast, rather than
      flagging the field. Off by default.

  Columns are matched by header name, ignoring case and surrounding space, so
  a column that has been renamed fails loudly rather than reading as the one
  next to it. Blank rows are skipped; a row with content and no id comes back
  as an event with `errors.id`, because dropping it would hide data someone
  typed.

      iex> log = Sheetshow.Log.new("expenses", item: :string)
      iex> rows = [["id", "deleted", "item"], ["a", nil, "Rent"], ["a", "TRUE", "Rent"]]
      iex> {:ok, events} = Sheetshow.Log.decode(rows, log)
      iex> Enum.map(events, &{&1.id, &1.row, &1.deleted})
      [{"a", 1, false}, {"a", 2, true}]

      iex> log = Sheetshow.Log.new("expenses", cost: :integer)
      iex> {:error, %Sheetshow.Error{reason: :missing_column}} =
      ...>   Sheetshow.Log.decode([["id", "deleted", "price"]], log)
  """
  @spec decode([[term()]], t(), keyword()) :: {:ok, [Event.t()]} | {:error, Error.t()}
  def decode(rows, %__MODULE__{} = log, opts \\ []) when is_list(rows) do
    opts = Keyword.validate!(opts, @decode_options)

    with {:ok, {_header, records}} <- Records.decode(rows, log, opts) do
      records |> Enum.map(&struct!(Event, &1)) |> Records.strict(opts)
    end
  end

  @doc """
  Same as `decode/3`, raising on failure.

      iex> log = Sheetshow.Log.new("expenses", item: :string)
      iex> Sheetshow.Log.decode!([["id", "deleted", "item"]], log)
      []
  """
  @spec decode!([[term()]], t(), keyword()) :: [Event.t()]
  def decode!(rows, %__MODULE__{} = log, opts \\ []) do
    rows |> decode(log, opts) |> Error.unwrap!()
  end

  @doc """
  Every event on the tab, in the order it was written.

  This is `Sheetshow.read_rows/2` over the whole tab and then `decode/3`, and
  it takes `decode/3`'s `:strict`. The values endpoint rather than the cell one
  because a stored row wants what its formulas worked out to, and because the
  schema already says which numbers are dates. See `Sheetshow.read_rows/2`
  for what that costs you.

  Reading the whole tab is what a fold needs; Google trims the answer to the
  rows that have something in them, so an empty log is one small request. A
  file is read whole whatever it holds.

      {:ok, workbook} = Sheetshow.connect(workbook)
      {:ok, events} = Sheetshow.Log.read(log, workbook)
      Sheetshow.Log.fold(events)

  ## Reading only what is new

  `after: event` answers with the events appended since that one, which is what
  a log too big to read every time needs. The cursor is an event you were given
  by a read, since its `row` is what makes it one, and the usual cursor is the
  last event you hold.

      {:ok, new} = Sheetshow.Log.read(log, workbook, after: List.last(events))
      state = Sheetshow.Log.fold(Sheetshow.Log.fold(events) ++ new)

  The read covers the cursor's own row as well as the rows below it, and the
  cursor's row must still hold the very same event. If it does not, because
  someone inserted or removed a row above it by hand, the rows you hold no longer
  line up with the sheet, and you get `{:error, %Error{reason: :moved}}` rather
  than a list that quietly means something else. Read the log whole when that
  happens.

  Two things this cannot see. A row appended and then deleted by hand *below*
  the cursor is simply gone, and nothing says so. And two neighbouring rows
  that are identical in every respect can stand in for each other, which is
  harmless, because folding either of them gives the same answer.

  At Google it is one request: the header row and the rows from the cursor
  down, asked for together, so the columns are still found by name rather than
  assumed. Against a file it is the file: a cursor saves the decoding, not the
  fetching, because a workbook has to be read whole before any of it can be.
  """
  @spec read(t(), Workbook.t(), keyword()) :: {:ok, [Event.t()]} | {:error, Error.t()}
  def read(%__MODULE__{} = log, %Workbook{} = workbook, opts \\ []) do
    opts = Keyword.validate!(opts, @read_options)

    case Keyword.fetch(opts, :after) do
      :error -> whole(log, workbook, opts)
      {:ok, cursor} -> since(log, workbook, cursor, opts)
    end
  end

  defp whole(log, workbook, opts) do
    with {:ok, rows} <- Sheetshow.read_rows(%Range{sheet: log.sheet}, workbook) do
      decode(rows, log, Keyword.take(opts, [:strict]))
    end
  end

  defp since(log, workbook, %Event{row: row} = cursor, opts) when is_integer(row) do
    ranges = [
      %Range{sheet: log.sheet, end_row: 0, end_col: last_col(log)},
      %Range{sheet: log.sheet, start_row: row, end_col: last_col(log)}
    ]

    with {:ok, [header, rows]} <- Sheetshow.read_rows(ranges, workbook),
         {:ok, events} <-
           decode(rows, log, [header: List.first(header) || [], row: row] ++ opts(opts)) do
      confirm(events, cursor)
    end
  end

  defp since(_log, _workbook, cursor, _opts) do
    raise ArgumentError,
          "after: takes an event a read gave you, which knows the row it sits on; " <>
            "got #{inspect(cursor)}"
  end

  defp opts(opts), do: Keyword.take(opts, [:strict])

  defp confirm(events, cursor) do
    case events do
      [^cursor | rest] ->
        {:ok, rest}

      _other ->
        {:error,
         Error.new(
           :moved,
           "row #{cursor.row} no longer holds the event you read there, so the rows above it " <>
             "have changed: read the log whole",
           row: cursor.row,
           expected: cursor,
           found: List.first(events)
         )}
    end
  end

  @doc "Same as `read/3`, raising on failure."
  @spec read!(t(), Workbook.t(), keyword()) :: [Event.t()]
  def read!(%__MODULE__{} = log, %Workbook{} = workbook, opts \\ []) do
    log |> read(workbook, opts) |> Error.unwrap!()
  end

  @doc """
  The log as it stands: the latest event for each id, in the order the ids
  first appeared, with the deleted ones gone.

      iex> alias Sheetshow.Log
      iex> log = [Log.Event.new(%{}, id: "a"), Log.Event.new(%{}, id: "b"), Log.Event.delete("a")]
      iex> Log.fold(log) |> Enum.map(& &1.id)
      ["b"]

  One pass over a map, so a hundred thousand rows fold in one go, and the
  result folds again: `fold(fold(old) ++ new)` is `fold(old ++ new)`, because
  the folded list keeps both the order the ids first appeared in and the latest
  content of each. So a process reading a log in batches can merge each read
  into what it holds instead of re-folding the lot. The one exception is an id
  that was deleted and then written again: it lands where it came back rather
  than where it started.

  A row whose id would not read takes no part in any of this, and cannot be
  updated or deleted by id, but it is kept, under its own row, so that data a
  person typed does not vanish from the fold.
  """
  @spec fold([Event.t()]) :: [Event.t()]
  def fold(events) when is_list(events) do
    {order, latest} =
      Enum.reduce(events, {[], %{}}, fn %Event{} = event, {order, latest} ->
        key = event.id || {:row, event.row}

        case latest do
          %{^key => _seen} -> {order, Map.put(latest, key, event)}
          _new -> {[key | order], Map.put(latest, key, event)}
        end
      end)

    order
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(latest, &1))
    |> Enum.reject(& &1.deleted)
  end
end
