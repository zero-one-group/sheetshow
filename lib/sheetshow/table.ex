defmodule Sheetshow.Table do
  @moduledoc """
  A tab of mutable rows, and the second of the two ways to keep data on a sheet.

  A table's rows are where a log's are events: row 7 *is* the record, and
  changing it means writing over row 7. That is the model people expect from a
  spreadsheet, and the one Google gives no conditional write for; see
  [What Sheetshow Can Promise](guides/guarantees.md). Everything here is
  arranged around that fact rather than around hiding it.

      iex> alias Sheetshow.Table
      iex> table = Table.new("costs", item: :string, cost: :decimal)
      iex> rows = [
      ...>   ["id", "deleted", "item", "cost"],
      ...>   ["a", nil, "Rent", "1000.00"],
      ...>   ["b", true, "Food", "400.00"]
      ...> ]
      iex> {:ok, snapshot} = Table.decode(rows, table)
      iex> Table.live(snapshot) |> Enum.map(&{&1.id, &1.row, &1.record.item})
      [{"a", 1, "Rent"}]

  What you hold between reading and writing is a `Sheetshow.Table.Snapshot`: the
  rows, and the row each of them sat on. A write is planned against a snapshot,
  so a snapshot is also the thing that goes stale: someone inserting a row by
  hand moves every row under it, and a plan made against the old positions would
  write to the wrong ones.

  The tab is laid out as a log's is. Row 0 is the header (`id`, `deleted`, then
  the schema's columns), and `deleted` is blank on a live row. Columns are found
  by header name, so a person's own columns to the right of the schema's are
  read past and never written over. Unlike a log, the schema's order is not
  forced on the tab: rows here are written by index, so the header says where
  each column is.

  Reading is lenient, as it is everywhere: a cell that will not cast leaves its
  field `nil` and an entry in the row's `errors`, and `strict: true` refuses
  such a read instead. Two rows sharing an id is the table's own version of
  that: the second one is flagged rather than dropped, because it is data
  somebody typed.

  ## The cycle

      {:ok, snapshot} = Table.read(table, workbook)          # one read, the whole tab

      changes = [
        Table.update(id, %{cost: "1100.00"}),
        Table.delete(other_id),
        Table.insert(%{item: "Fuel", cost: "50.00"})
      ]

      {:ok, snapshot} = Table.refresh(snapshot, workbook)     # one read, the id column
      {:ok, workbook} = changes |> Table.plan!(snapshot) |> Sheetshow.run(workbook)

  There is no `verify` and no `commit`: checking a snapshot *is* a fresh read,
  and the library's job is to make that read cheap and re-planning free. A
  change names its row by id, so `plan/2` is pure and can be run again against
  whatever `refresh/2` finds, and a cycle costs three requests, or two without
  the refresh. The refresh catches rows that have moved; reading again catches a
  cell somebody edited under you; nothing closes the gap between the last read
  and the write. A store with a conditional write makes each `run/2` atomic, so
  a writer racing it is refused rather than silently overwriting, but it does not
  yet tie the write to the snapshot the plan was made against; see
  [What Sheetshow Can Promise](guides/guarantees.md).

  Queries are `Enum` over `live/1`, since schemas are data and there is no
  query language here.
  """

  alias Sheetshow.{Error, Op, Range, Records, Result, Runs, Schema, ULID, Workbook}
  alias Sheetshow.Table.{Change, Row, Snapshot}

  @enforce_keys [:sheet, :schema]
  defstruct [:sheet, :schema]

  @type t :: %__MODULE__{sheet: String.t(), schema: Schema.t()}

  @decode_options [:header, :row, :strict]
  @read_options [:strict]

  @doc """
  A table on a tab, with the columns its rows have. Raises `ArgumentError` on a
  schema `Sheetshow.Schema.validate/1` refuses, and on one that names an `id` or
  `deleted` column, which the model keeps for itself.

      iex> Sheetshow.Table.new("costs", item: :string, cost: :decimal).sheet
      "costs"
  """
  @spec new(String.t(), Schema.t()) :: t()
  def new(sheet, schema) when is_binary(sheet) do
    case Records.validate_schema(schema) do
      :ok -> %__MODULE__{sheet: sheet, schema: schema}
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  @doc """
  The columns a new tab is given, left to right. What is on the tab afterwards
  is the tab's business; see `decode/3`.

      iex> Sheetshow.Table.new("costs", item: :string) |> Sheetshow.Table.columns()
      ["id", "deleted", "item"]
  """
  @spec columns(t()) :: [String.t()]
  def columns(%__MODULE__{schema: schema}), do: Records.columns(schema)

  @doc """
  The header as cells, bold unless you say otherwise.

      iex> Sheetshow.Table.new("costs", item: :string)
      ...> |> Sheetshow.Table.header()
      ...> |> Sheetshow.to_rows()
      [["id", "deleted", "item"]]
  """
  @spec header(t(), Sheetshow.Style.t()) :: [Sheetshow.Cell.t()]
  def header(%__MODULE__{} = table, style \\ %{bold: true}), do: Records.header(table, style)

  @doc """
  The plan that makes the tab and writes its header. Fails at the backend if the
  tab is already there, which is what you want from something called `create`.

      iex> Sheetshow.Table.new("costs", item: :string)
      ...> |> Sheetshow.Table.create()
      ...> |> Enum.map(&Sheetshow.Op.sheet/1)
      ["costs", "costs"]
  """
  @spec create(t()) :: Op.plan()
  def create(%__MODULE__{} = table), do: Sheetshow.plan!(header(table), existing_sheets: [])

  @doc """
  The snapshot of a tab that has just been made: the header `create/1` writes,
  and no rows.

  It is what lets a table be created and filled in one request, with nothing to
  read first: an insert does not depend on where anything sits, so a snapshot
  of an empty tab is all `plan/2` needs to place one.

      plan = Sheetshow.Table.create(table) ++ Sheetshow.Table.plan!(rows, Sheetshow.Table.empty(table))
      {:ok, workbook} = Sheetshow.run(plan, workbook)

  Only for a tab you are making in the same breath. For one that is already
  there, `read/3`: its header is whatever is on it.

      iex> table = Sheetshow.Table.new("costs", item: :string)
      iex> Sheetshow.Table.empty(table).header
      ["id", "deleted", "item"]
  """
  @spec empty(t()) :: Snapshot.t()
  def empty(%__MODULE__{} = table) do
    %Snapshot{table: table, header: columns(table), rows: []}
  end

  @doc """
  A snapshot from the tab's values: rows of cell values, as
  `Sheetshow.read_rows/2` or `Sheetshow.to_rows/1` gives them.

  Options:

    * `:header`, the header row, when `rows` holds only data. Without it the
      first row of `rows` is the header.
    * `:row`, the sheet row the first given row sits on, so rows know where
      they are. Defaults to `0` with a header in `rows`, `1` without.
    * `:strict`, to refuse the read when any cell would not cast or any id is
      missing or repeated, rather than flagging the row. Off by default.

  Columns are matched by header name, ignoring case and surrounding space, so a
  column that has been renamed fails loudly rather than reading as the one next
  to it. Blank rows are skipped, and the rows that are left keep the sheet rows
  they came from, which is what a write later needs.

      iex> table = Sheetshow.Table.new("costs", item: :string)
      iex> rows = [["id", "deleted", "item"], ["a", nil, "Rent"], ["a", nil, "Food"]]
      iex> {:ok, snapshot} = Sheetshow.Table.decode(rows, table)
      iex> Enum.map(snapshot.rows, &{&1.row, Map.has_key?(&1.errors, :id)})
      [{1, false}, {2, true}]

      iex> table = Sheetshow.Table.new("costs", cost: :integer)
      iex> {:error, %Sheetshow.Error{reason: :missing_column}} =
      ...>   Sheetshow.Table.decode([["id", "deleted", "price"]], table)
  """
  @spec decode([[term()]], t(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def decode(rows, %__MODULE__{} = table, opts \\ []) when is_list(rows) do
    opts = Keyword.validate!(opts, @decode_options)

    with {:ok, {header, records}} <- Records.decode(rows, table, opts),
         decoded = records |> Enum.map(&struct!(Row, &1)) |> flag_repeats(),
         {:ok, decoded} <- Records.strict(decoded, opts) do
      {:ok, %Snapshot{table: table, header: header, rows: decoded}}
    end
  end

  @doc """
  Same as `decode/3`, raising on failure.

      iex> table = Sheetshow.Table.new("costs", item: :string)
      iex> Sheetshow.Table.decode!([["id", "deleted", "item"]], table).rows
      []
  """
  @spec decode!([[term()]], t(), keyword()) :: Snapshot.t()
  def decode!(rows, %__MODULE__{} = table, opts \\ []) do
    rows |> decode(table, opts) |> Error.unwrap!()
  end

  @doc """
  The tab as it stands, as a snapshot. Takes `decode/3`'s `:strict`.

  This is `Sheetshow.read_rows/2` over the whole tab and then `decode/3`: the
  values endpoint rather than the cell one, because a stored row wants what its
  formulas worked out to, and the schema already says which numbers are dates.
  See `Sheetshow.read_rows/2` for what that costs you.

  At Google it is one request whatever the tab holds, its answer trimmed to the
  rows with something in them. Against a file it is the file: a workbook is read
  whole before any one tab of it can be.

      {:ok, snapshot} = Sheetshow.Table.read(table, workbook)
      snapshot |> Sheetshow.Table.live() |> Enum.filter(&(&1.record.cost > 500))
  """
  @spec read(t(), Workbook.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def read(%__MODULE__{} = table, %Workbook{} = workbook, opts \\ []) do
    opts = Keyword.validate!(opts, @read_options)

    with {:ok, rows} <- Sheetshow.read_rows(%Range{sheet: table.sheet}, workbook) do
      decode(rows, table, opts)
    end
  end

  @doc "Same as `read/3`, raising on failure."
  @spec read!(t(), Workbook.t(), keyword()) :: Snapshot.t()
  def read!(%__MODULE__{} = table, %Workbook{} = workbook, opts \\ []) do
    table |> read(workbook, opts) |> Error.unwrap!()
  end

  @doc """
  The same snapshot, with the rows found where they are now: one request for
  the header row and the id column, asked for together.

  A plan cannot be made to apply only if the sheet is as you read it; what it
  can be is *recent*. A change names its row by id, never by position, so
  re-planning against fresh positions is pure and free, and one column's worth
  of bytes turns a snapshot minutes old into one milliseconds old.

      {:ok, snapshot} = Sheetshow.Table.refresh(snapshot, workbook)
      {:ok, workbook} = changes |> Sheetshow.Table.plan!(snapshot) |> Sheetshow.run(workbook)

  It catches rows inserted, removed or moved anywhere on the tab. It does not
  catch somebody editing a cell of a row you are about to write; only `read/3`
  would, though an update writes only the columns it names, so another column's
  change survives anyway. Against a file there is no small read: `refresh/2`
  costs what `read/3` costs.

  Rows whose id is no longer on the tab drop out, because that is the truth
  about the sheet; a change that named one then fails in `plan/2` as
  `:unknown_id`. Rows the snapshot never read stay unread, since refreshing is
  about where things are, not what they say. If the header itself has changed,
  the column positions the snapshot holds are no longer true and you get
  `{:error, %Sheetshow.Error{reason: :moved}}`: read again.
  """
  @spec refresh(Snapshot.t(), Workbook.t()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def refresh(%Snapshot{table: table, header: header} = snapshot, %Workbook{} = workbook) do
    with {:ok, index} <- Records.index(header, table.sheet, table.schema) do
      id_col = index[Records.id_column()]

      ranges = [
        %Range{sheet: table.sheet, end_row: 0, end_col: max(length(header) - 1, id_col)},
        %Range{sheet: table.sheet, start_row: 1, start_col: id_col, end_col: id_col}
      ]

      with {:ok, [heading, ids]} <- Sheetshow.read_rows(ranges, workbook),
           {:ok, fresh} <- Records.index(List.first(heading) || [], table.sheet, table.schema),
           :ok <- unmoved(fresh, index, table.sheet) do
        {:ok, %{snapshot | rows: relocate(snapshot.rows, ids)}}
      end
    end
  end

  defp unmoved(fresh, index, sheet) do
    if fresh == index do
      :ok
    else
      {:error,
       Error.new(
         :moved,
         "#{inspect(sheet)} no longer has its columns where this snapshot found them, so the " <>
           "rows in it cannot be placed: read the table again",
         was: index,
         now: fresh
       )}
    end
  end

  # The id column says where every id is now. A row whose id is gone goes with
  # it; an id that turns up twice makes both rows unwritable, and says so on the
  # one the snapshot is holding rather than quietly picking one. An id the
  # snapshot itself read twice stays unwritable too, even when the tab now has
  # it once: the snapshot holds two records for it and cannot tell which one
  # the row still is, so only a fresh read can.
  defp relocate(rows, ids) do
    found =
      ids
      |> Enum.with_index(1)
      |> Enum.reduce(%{}, fn {cells, number}, acc ->
        case List.first(cells) do
          blank when blank in [nil, ""] -> acc
          id -> Map.update(acc, to_string(id), [number], &(&1 ++ [number]))
        end
      end)

    held = rows |> Enum.map(& &1.id) |> Enum.frequencies()

    rows
    |> Enum.flat_map(fn %Row{} = row ->
      case {Map.get(found, row.id), Map.get(held, row.id, 0)} do
        {nil, _held} -> []
        {[number], 1} -> [%{row | row: number, errors: Map.delete(row.errors, :id)}]
        {[number], _twice} -> [%{row | row: number, errors: stale(row, rows)}]
        {[number | _] = all, _held} -> [%{row | row: number, errors: repeated(row, all)}]
      end
    end)
    |> Enum.sort_by(& &1.row)
  end

  defp repeated(%Row{} = row, numbers) do
    Map.put(row.errors, :id, ambiguous(row.id, numbers))
  end

  defp stale(%Row{id: id} = row, rows) do
    was = for %Row{id: ^id, row: number} <- rows, do: number

    error =
      Error.new(
        :duplicate_id,
        "rows #{Enum.join(was, " and ")} both had id #{inspect(id)} when this snapshot was " <>
          "read, and the tab now has it once, so there is no telling which record is left: " <>
          "read the table again",
        id: id,
        rows: was
      )

    Map.put(row.errors, :id, error)
  end

  @doc """
  The rows a reader would call the table's contents: the ones not tombstoned.

  `snapshot.rows` is everything, tombstones included, for when what was taken
  out matters.

      iex> table = Sheetshow.Table.new("costs", item: :string)
      iex> rows = [["id", "deleted", "item"], ["a", nil, "Rent"], ["b", true, "Food"]]
      iex> Sheetshow.Table.decode!(rows, table) |> Sheetshow.Table.live() |> Enum.map(& &1.id)
      ["a"]
  """
  @spec live(Snapshot.t()) :: [Row.t()]
  def live(%Snapshot{rows: rows}), do: Enum.reject(rows, & &1.deleted)

  @doc """
  The live row with this id, if the snapshot has one. Everything else a query
  might want is `Enum` over `live/1`.

      iex> table = Sheetshow.Table.new("costs", item: :string)
      iex> rows = [["id", "deleted", "item"], ["a", nil, "Rent"], ["b", true, "Food"]]
      iex> snapshot = Sheetshow.Table.decode!(rows, table)
      iex> {:ok, row} = Sheetshow.Table.fetch(snapshot, "a")
      iex> {row.record.item, row.row}
      {"Rent", 1}
      iex> Sheetshow.Table.fetch(snapshot, "b")
      :error
  """
  @spec fetch(Snapshot.t(), String.t()) :: {:ok, Row.t()} | :error
  def fetch(%Snapshot{} = snapshot, id) when is_binary(id) do
    case Enum.find(live(snapshot), &(&1.id == id)) do
      nil -> :error
      row -> {:ok, row}
    end
  end

  @doc """
  A row to add, with an id of its own unless you pass one. Takes `:id`, any
  non-empty string, exactly as a log's events do.

  An insert is the one change that does not depend on where anything sits:
  `appendCells` resolves below the last row with data when Google applies it,
  not when the plan is made, so a plan of nothing but inserts is safe against a
  snapshot of any age.

      iex> Sheetshow.Table.insert(%{item: "Fuel"}, id: "f").id
      "f"
  """
  @spec insert(Schema.fields(), keyword()) :: Change.t()
  def insert(record, opts \\ []) when is_map(record) and is_list(opts) do
    opts = Keyword.validate!(opts, [:id])
    %Change{action: :insert, id: id(Keyword.get(opts, :id)), record: record}
  end

  @doc """
  A change to the columns it names on the row with this id, leaving every other
  cell on that row as it is.

  Naming a column with `nil` empties it; not naming it leaves it alone. So an
  update never writes over a column it was not asked about, which is what lets
  a person keep working in the same tab.

      iex> Sheetshow.Table.update("a", %{cost: "1100.00"}).record
      %{cost: "1100.00"}
  """
  @spec update(String.t(), Schema.fields()) :: Change.t()
  def update(id, record) when is_binary(id) and is_map(record) do
    %Change{action: :update, id: id, record: record}
  end

  @doc """
  Takes a row out. By default that means setting its `deleted` flag: one cell,
  nothing below it moves, and a plan aimed at a row that has since shifted
  leaves a flag in the wrong place rather than destroying a record.

  `hard: true` plans a real `Sheetshow.Op.DeleteRows` instead. That is the
  destructive one, since it takes the whole row, a person's own columns
  included, and shifts everything below, so it is worth being sure the snapshot
  is fresh. `compact/1` is the usual way to want this.

      iex> Sheetshow.Table.delete("a").hard
      false
  """
  @spec delete(String.t(), keyword()) :: Change.t()
  def delete(id, opts \\ []) when is_binary(id) and is_list(opts) do
    opts = Keyword.validate!(opts, hard: false)
    %Change{action: :delete, id: id, hard: Keyword.fetch!(opts, :hard)}
  end

  @doc """
  Puts a soft-deleted row back: empties its `deleted` flag. Nothing a hard
  delete took can be restored.

      iex> Sheetshow.Table.restore("a").action
      :restore
  """
  @spec restore(String.t()) :: Change.t()
  def restore(id) when is_binary(id), do: %Change{action: :restore, id: id}

  @doc """
  The plan that carries out these changes against the tab as this snapshot
  found it.

  Pure, and strict as writing always is: a value that does not fit the schema,
  a column the schema has not got, an id the snapshot cannot place, or two
  changes to one id are all errors here rather than surprises in the sheet. An
  empty list is an empty plan.

      iex> alias Sheetshow.Table
      iex> table = Table.new("costs", item: :string, cost: :decimal)
      iex> rows = [["id", "deleted", "item", "cost"], ["a", nil, "Rent", "1000.00"]]
      iex> snapshot = Table.decode!(rows, table)
      iex> {:ok, plan} = [Table.update("a", %{cost: "1100.00"})] |> Table.plan(snapshot)
      iex> Enum.map(plan, &Sheetshow.Op.PutCells.range(&1)) |> Enum.map(&Sheetshow.Range.to_a1/1)
      ["costs!A2", "costs!D2"]

  Two writes for one update, because the columns are not next to each other and
  a `Sheetshow.Op.PutCells` is a run without gaps: the `cost` cell, and the id
  cell. **An update always writes its row's id back.** It costs nothing (a plan
  is one request however many ops it holds) and it is what makes a write that
  landed on the wrong row visible: the tab then has that id twice, and the next
  read flags it, where otherwise a record would have been quietly overwritten
  and still look fine.

  ## The order the ops go in

  Updates first, then the one `Sheetshow.Op.AppendRows` that carries every
  insert, then any hard deletes, **last and bottom-up**. Deleting a row moves
  everything under it, so row numbers taken from the snapshot are only true
  before the first delete applies; putting them last and in descending order is
  what keeps the rest of the plan aimed at the rows it was aimed at. That is the
  planner's job, not yours.

  The plan is applied whole or not at all. The gap between the read the snapshot
  came from and the write is not covered: `refresh/2` makes it short. A store
  with a conditional write makes each `run/2` atomic against another writer, but
  does not yet close that gap, because `run/2` re-reads the file rather than
  writing against the snapshot's version; see
  [What Sheetshow Can Promise](guides/guarantees.md).
  """
  @spec plan([Change.t()], Snapshot.t()) :: {:ok, Op.plan()} | {:error, Error.t()}
  def plan([], %Snapshot{}), do: {:ok, []}

  def plan(changes, %Snapshot{table: table} = snapshot) when is_list(changes) do
    with :ok <- one_change_each(changes),
         {:ok, index} <- Records.index(snapshot.header, table.sheet, table.schema) do
      compile(changes, snapshot, index)
    end
  end

  @doc """
  Same as `plan/2`, raising on failure.

      iex> table = Sheetshow.Table.new("costs", item: :string)
      iex> snapshot = Sheetshow.Table.decode!([["id", "deleted", "item"]], table)
      iex> Sheetshow.Table.plan!([], snapshot)
      []
  """
  @spec plan!([Change.t()], Snapshot.t()) :: Op.plan()
  def plan!(changes, %Snapshot{} = snapshot), do: changes |> plan(snapshot) |> Error.unwrap!()

  @doc """
  The plan that takes every soft-deleted row off the tab for good, bottom-up and
  in one batch. The tidying half of soft delete, for when the tombstones have
  served their purpose.

  It is a plan rather than an `{:ok, plan}`. But it is a hard delete, and a stale
  snapshot means deleting the wrong rows. Refresh, or read again, immediately
  before. A tombstone whose id another row shares (which a `refresh/2` flags, and
  which leaves both rows pointing at the first of their positions) is **left in
  place** rather than deleted at a position that may not be its own: a fresh read
  that shows the id once is what lets it go.

      iex> table = Sheetshow.Table.new("costs", item: :string)
      iex> rows = [["id", "deleted", "item"], ["a", nil, "Rent"], ["b", true, "Food"]]
      iex> plan = Sheetshow.Table.decode!(rows, table) |> Sheetshow.Table.compact()
      iex> Enum.map(plan, & &1.rows)
      [2..2]
  """
  @spec compact(Snapshot.t()) :: Op.plan()
  def compact(%Snapshot{table: table, rows: rows}) do
    rows
    |> Enum.filter(&(&1.deleted and not flagged?(&1)))
    |> Enum.map(& &1.row)
    |> deletes(table.sheet)
  end

  # A row wearing an id flag cannot be placed: after a refresh, two rows sharing
  # an id both point at the first of their positions, so compacting the deleted
  # one would delete whatever now sits there, the live one included.
  defp flagged?(%Row{errors: %{id: _}}), do: true
  defp flagged?(%Row{}), do: false

  # Two changes to one id in one batch is a question about order that the
  # caller has not answered, and `updateCells` then `deleteRow` on the same row
  # means something quite different from the other way round.
  defp one_change_each(changes) do
    ids = for %Change{id: id} <- changes, is_binary(id), do: id

    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      [id | _] ->
        {:error,
         Error.new(
           :conflicting_changes,
           "more than one change names #{inspect(id)}: make them one change, or two plans",
           id: id
         )}
    end
  end

  defp compile(changes, snapshot, index) do
    with {:ok, {puts, inserts, deletes}} <-
           Result.reduce(changes, {[], [], []}, fn change, acc ->
             with {:ok, part} <- compile_one(change, snapshot, index),
                  do: {:ok, collect(acc, part)}
           end) do
      sheet = snapshot.table.sheet

      {:ok,
       Enum.reverse(puts) ++ appends(Enum.reverse(inserts), sheet) ++ deletes(deletes, sheet)}
    end
  end

  # Reversed on the way in, because the whole list is reversed on the way out.
  defp collect({puts, inserts, deletes}, {:put, ops}) do
    {Enum.reverse(ops) ++ puts, inserts, deletes}
  end

  defp collect({puts, inserts, deletes}, {:insert, row}), do: {puts, [row | inserts], deletes}
  defp collect({puts, inserts, deletes}, {:delete, row}), do: {puts, inserts, [row | deletes]}

  defp compile_one(%Change{action: :insert, id: id, record: record}, snapshot, index) do
    with :ok <- unused(id, snapshot),
         {:ok, pairs} <- named(record, snapshot.table.schema, index) do
      {:ok,
       {:insert, [{index[Records.id_column()], id} | Enum.reject(pairs, &is_nil(elem(&1, 1)))]}}
    end
  end

  defp compile_one(%Change{action: :update, id: id, record: record}, snapshot, index) do
    with {:ok, row} <- locate(id, snapshot),
         {:ok, pairs} <- named(record, snapshot.table.schema, index) do
      cells = [{index[Records.id_column()], id} | pairs]
      {:ok, {:put, puts(row.row, cells, snapshot.table.sheet)}}
    end
  end

  defp compile_one(%Change{action: :delete, id: id, hard: true}, snapshot, _index) do
    with {:ok, row} <- locate(id, snapshot), do: {:ok, {:delete, row.row}}
  end

  defp compile_one(%Change{action: action, id: id}, snapshot, index)
       when action in [:delete, :restore] do
    flag = if action == :delete, do: true, else: nil

    with {:ok, row} <- locate(id, snapshot) do
      cells = [{index[Records.id_column()], id}, {index[Records.deleted_column()], flag}]
      {:ok, {:put, puts(row.row, cells, snapshot.table.sheet)}}
    end
  end

  # Only the columns the record names: an update leaves the rest of the row as
  # it found it, and a column named with `nil` is one the caller wants empty.
  defp named(record, schema, index) do
    with {:ok, values} <- Schema.encode(record, schema) do
      pairs =
        for {{name, _type}, value} <- Enum.zip(schema, values),
            Map.has_key?(record, name),
            do: {index[to_string(name)], value}

      {:ok, pairs}
    end
  end

  # A row wearing a flag on its id says why it cannot be written to, and that
  # reason beats a count of rows, which after a refresh may all be the same row.
  defp locate(id, %Snapshot{rows: rows}) do
    case Enum.filter(rows, &(&1.id == id)) do
      [] -> {:error, unknown_id(id)}
      [%Row{errors: %{id: error}} | _] -> {:error, unwritable(id, error)}
      [%Row{} = row] -> {:ok, row}
      [_, _ | _] = many -> {:error, ambiguous(id, Enum.map(many, & &1.row))}
    end
  end

  defp unused(id, %Snapshot{rows: rows}) do
    case Enum.find(rows, &(&1.id == id)) do
      nil -> :ok
      %Row{row: row} -> {:error, taken(id, row)}
    end
  end

  defp puts(row, pairs, sheet) do
    pairs
    |> runs()
    |> Enum.map(fn run ->
      run
      |> Enum.map(fn {col, value} -> Records.cell(row, col, value) end)
      |> Op.PutCells.new(sheet)
    end)
  end

  defp appends([], _sheet), do: []

  defp appends(rows, sheet) do
    cells =
      for {pairs, offset} <- Enum.with_index(rows),
          {col, value} <- pairs,
          do: Records.cell(offset, col, value)

    [Op.AppendRows.new(cells, sheet)]
  end

  # A PutCells is a run without gaps, so scattered columns become several ops,
  # which is also what leaves the columns in between exactly as they were.
  defp runs(pairs) do
    pairs |> Enum.sort_by(&elem(&1, 0)) |> Runs.consecutive(&elem(&1, 0))
  end

  # Bottom-up, and neighbours merged, so a batch of deletes applies from the
  # last row and the rows it has not reached yet have not moved.
  defp deletes(rows, sheet) do
    rows |> Runs.ranges() |> Enum.reverse() |> Enum.map(&Op.DeleteRows.new(sheet, &1))
  end

  defp unknown_id(id) do
    Error.new(
      :unknown_id,
      "the snapshot has no row with id #{inspect(id)}: read the table again, or insert it",
      id: id
    )
  end

  defp ambiguous(id, rows) do
    Error.new(
      :duplicate_id,
      "rows #{Enum.join(rows, " and ")} both have id #{inspect(id)}, so there is no one row " <>
        "to write: put that right on the tab first",
      id: id,
      rows: rows
    )
  end

  defp unwritable(id, error) do
    Error.new(
      :duplicate_id,
      "the row with id #{inspect(id)} cannot be written to: #{Exception.message(error)}",
      id: id
    )
  end

  defp taken(id, row) do
    Error.new(
      :duplicate_id,
      "row #{row} already has id #{inspect(id)}: an insert makes a new row, an update changes " <>
        "the one that is there",
      id: id,
      row: row
    )
  end

  defp id(nil), do: ULID.generate()
  defp id(given) when is_binary(given) and given != "", do: given

  defp id(other) do
    raise ArgumentError, "a row's id is a non-empty string, got #{inspect(other)}"
  end

  # An id is a table's way of finding a row again, so two rows wearing one is a
  # question only a person can answer. The first keeps it and the rest are
  # flagged: dropping them would hide something somebody typed, and refusing the
  # read would make a tab nobody could look at until they had fixed it by hand.
  defp flag_repeats(rows) do
    {flagged, _seen} =
      Enum.map_reduce(rows, %{}, fn
        %Row{id: nil} = row, seen ->
          {row, seen}

        %Row{id: id} = row, seen ->
          case seen do
            %{^id => first} -> {repeat(row, id, first), seen}
            _ -> {row, Map.put(seen, id, row.row)}
          end
      end)

    flagged
  end

  defp repeat(row, id, first) do
    error =
      Error.new(
        :duplicate_id,
        "row #{row.row} has the same id as row #{first}, so #{inspect(id)} says nothing " <>
          "about which row to write",
        column: :id,
        value: id,
        row: row.row,
        first: first
      )

    %{row | errors: Map.put(row.errors, :id, error)}
  end
end
