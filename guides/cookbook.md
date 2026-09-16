# Cookbook

Recipes for the things people actually do with a spreadsheet. Every snippet is
complete apart from `workbook`, which the first two recipes make, and every
snippet from the third recipe on is run by the test suite, in order, against the
in-memory and the xlsx backends.

Two habits run through all of it. **A plan is a value**, so build the whole thing
and run it once rather than writing as you go: one request costs the same
whether it carries one op or five hundred, and the quota counts requests.
**Plans are lists**, so `++` is how a tab, its header and its first rows become
a single write.

## Reach a Google spreadsheet

<!-- guide-test: skip -->
```elixir
account = Sheetshow.ServiceAccount.from_file!("service-account.json")

{:ok, workbook} =
  "1AbC...the id from the URL"
  |> Sheetshow.Workbook.google(credentials: account)
  |> Sheetshow.connect()
```

The spreadsheet has to be shared with the service account's email, the same as
with a person. `connect/1` mints a token and reads the sheet list; call it once
per workbook, not once per operation. For a user rather than a robot, swap in
`Sheetshow.UserAccount.from_file!/1`; everything downstream is identical.

## Reach an .xlsx file instead

<!-- guide-test: skip -->
```elixir
{:ok, workbook} = Sheetshow.connect(Sheetshow.Workbook.xlsx("costs.xlsx"))

# One that does not exist yet:
{:ok, workbook} = Sheetshow.connect(Sheetshow.Workbook.xlsx("new.xlsx", create: true))

# One on Nextcloud, where If-Match makes a write conditional:
store = Sheetshow.Store.nextcloud("https://cloud.example.com", "user", "costs.xlsx",
          password: System.fetch_env!("NEXTCLOUD_APP_PASSWORD"))

{:ok, workbook} = Sheetshow.connect(Sheetshow.Workbook.xlsx(store))
```

Everything below works against any of these. What differs is what the backend
will promise, which is `Sheetshow.Backend.capabilities/1`, and the two recipes
that need a promise say so.

## Write records to a tab

```elixir
costs = [
  %{item: "Rent", cost: 1000.0, due: ~D[2026-10-01]},
  %{item: "Food", cost: 400.0, due: ~D[2026-10-05]}
]

cells =
  Sheetshow.stack([
    Sheetshow.row(["Item", "Cost", "Due"], style: %{bold: true}),
    Sheetshow.records(costs, [:item, :cost, :due])
  ])
  |> Sheetshow.put_sheet("Costs")

{:ok, workbook} =
  cells
  |> Sheetshow.plan!(existing_sheets: Sheetshow.Workbook.titles(workbook))
  |> Sheetshow.run(workbook)
```

`:existing_sheets` is what makes this work whether or not the tab is there: any
sheet the cells name that is not on the list gets an `AddSheet` at the front of
the plan. Leave the option out and the plan assumes every tab exists.

The dates need no help: a date with no `:number_format` of its own gets one
that reads as a date.

## Lay several blocks out on one tab

```elixir
quarters = [["Q1", 1400.0], ["Q2", 1450.0], ["Q3", 1380.0]]
total = quarters |> Enum.map(&Enum.at(&1, 1)) |> Enum.sum()
average = total / length(quarters)
gap = 2

report =
  Sheetshow.stack([
    Sheetshow.row(["Quarterly costs"], style: %{bold: true, font_size: 14}),
    Sheetshow.rows(quarters) |> Sheetshow.pad_below(gap),
    Sheetshow.beside([
      Sheetshow.col(["Total", "Average"], style: %{bold: true}),
      Sheetshow.col([total, average])
    ])
  ])
  |> Sheetshow.put_sheet("Report")

"Report!A1:B8" = report |> Sheetshow.Range.bounding() |> Sheetshow.Range.to_a1()
```

`stack/1` puts each group on the row after the last one above it, keeping
each group's own internal offsets; `pad_below/2` holds empty rows so the next
group starts lower. For room *above* or *left* of a group, `shift/3` moves it and
the offset survives concatenation:

```elixir
notes = Sheetshow.row(["See the sheet for details"], sheet: "Report")

"Report!A3" = notes |> Sheetshow.shift(2, 0) |> Sheetshow.Range.bounding() |> Sheetshow.Range.to_a1()
```

## Style cells, and size their columns

```elixir
header = Sheetshow.row(["Item", "Cost"], style: %{bold: true, background: "#EFEFEF", col_width: 160})
amounts = Sheetshow.col([1000.0, 400.0], style: %{number_format: "#,##0.00"})

%{bold: true, italic: true, background: "#EFEFEF", col_width: 160} =
  header |> Sheetshow.put_style(%{italic: true}) |> hd() |> Map.fetch!(:style)
```

A style is a plain map, so `Map.merge/2` composes styles and there is no fixed
set to subclass. `:col_width` and `:row_height` describe the column and row the
cell sits in rather than the cell, and the planner lifts them out into a
`Sheetshow.Op.SetDimensions` of their own.

## Read a tab back

```elixir
{:ok, rows} = Sheetshow.read_rows("Costs", workbook)
[["Item", "Cost", "Due"], ["Rent", _cost, _due] | _] = rows

{:ok, cells} = Sheetshow.read_cells("Costs!A1:C10", workbook)
%{bold: true} = hd(cells).style
```

Two reads, and the choice matters. `read_rows/2` asks for the computed values
alone and is about a twelfth the bytes, so it is what the database layer below
uses, and what you want for anything row-shaped. `read_cells/2` asks for cells and
gets everything about them: what was entered, what the spreadsheet made of it
(`meta.effective`), the text it displayed (`meta.formatted`) and the format. A
formula reads back as a formula there, so cells you read are cells you can write
again; through `read_rows/2` a formula arrives as its answer and cannot.

Given a list of ranges, `read_rows/2` asks for all of them in one request:

```elixir
{:ok, [header, rest]} = Sheetshow.read_rows(["Costs!A1:C1", "Costs!A2:C"], workbook)
[["Item", "Cost", "Due"]] = header
2 = length(rest)
```

## Change a few cells and leave their neighbours alone

```elixir
{:ok, workbook} =
  [
    Sheetshow.Cell.new("B2", 1100.0),
    Sheetshow.Cell.new("D7", "checked")
  ]
  |> Sheetshow.plan!(sheet: "Costs")
  |> Sheetshow.run(workbook)
```

Scattered cells become one `PutCells` per contiguous run, so nothing between
them is touched. Writing a cell replaces its value *and* its format together,
because cells are values rather than patches, so a cell written without a style
comes back unstyled.

## Keep an append-only log on a tab

```elixir
schema = [item: :string, cost: :decimal, due: :date, paid: :boolean]
log = Sheetshow.Log.new("expenses log", schema)

events = [
  Sheetshow.Log.Event.new(%{item: "Rent", cost: "1000.00", due: ~D[2026-10-01], paid: false}),
  Sheetshow.Log.Event.new(%{item: "Food", cost: "400.00", due: ~D[2026-10-05], paid: false})
]

# The tab, its header and its first rows, in one request.
{:ok, workbook} =
  Sheetshow.run(Sheetshow.Log.create(log) ++ Sheetshow.Log.plan!(events, log), workbook)

{:ok, events} = Sheetshow.Log.read(log, workbook)
["Rent", "Food"] = events |> Sheetshow.Log.fold() |> Enum.map(& &1.record.item)
```

An update is the same id appended again and a delete is the same id with the
flag; `fold/1`, where the latest event per id wins and tombstoned ids drop out,
turns the history back into state.

```elixir
rent = Enum.find(events, &(&1.record.item == "Rent"))

changes = [
  Sheetshow.Log.Event.put(rent, %{cost: "1100.00"}),
  Sheetshow.Log.Event.delete("some-other-id")
]

{:ok, workbook} = Sheetshow.run(Sheetshow.Log.plan!(changes, log), workbook)
```

**This is the model to reach for when more than one thing writes**, because
Google resolves an append server-side and a file store with a conditional write
refuses the loser; [What Sheetshow Can Promise](guarantees.md) has the whole
argument. One caveat: retry a failed batch *before* writing anything newer, or
the stale retry lands as the newest row and wins the fold.

## Read only the rows you have not seen

```elixir
{:ok, new} = Sheetshow.Log.read(log, workbook, after: List.last(events))
state = Sheetshow.Log.fold(Sheetshow.Log.fold(events) ++ new)

[{"Rent", "1100.00"}, {"Food", "400.00"}] = Enum.map(state, &{&1.record.item, &1.record.cost})
```

The cursor must be an event a read gave you, since its `row` is what makes it
one.
`fold/1` is incremental for free: folding what you hold plus what is new gives
the same answer as folding everything. If someone has inserted or deleted rows
above the cursor you get `%Sheetshow.Error{reason: :moved}` rather than a list
that quietly means something else; read the log whole when that happens.

## Show the log's current state in the spreadsheet

```elixir
{:ok, workbook} =
  log
  |> Sheetshow.Log.view("expenses now")
  |> Sheetshow.plan!(existing_sheets: Sheetshow.Workbook.titles(workbook))
  |> Sheetshow.run(workbook)
```

One formula that works `fold/1` out in Sheets, so the tab stays current as rows
are appended and a person looking at the spreadsheet sees state rather than
history. It uses `SORTN`, so it needs a backend that evaluates formulas: Google
does, a file does not.

On a file, compute it and write plain rows instead:

```elixir
cells =
  Sheetshow.stack([
    Sheetshow.row(["id" | Sheetshow.Schema.columns(schema)], style: %{bold: true}),
    Sheetshow.records(
      Enum.map(state, &Map.put(&1.record, :id, &1.id)),
      [:id | Keyword.keys(schema)]
    )
  ])
  |> Sheetshow.put_sheet("expenses now")
```

That is a snapshot rather than a view: it is stale as soon as anything is
appended, and you rewrite it when you want it current. Rebuild the tab rather
than writing over it, with
`[Sheetshow.Op.DeleteSheet.new("expenses now")] ++ plan`, because a shorter
state written over a longer one leaves the old tail behind.

## Keep a table of rows you overwrite

```elixir
table = Sheetshow.Table.new("expenses", schema)

# create/1 ++ plan against empty/1 needs nothing read first
inserts = [
  Sheetshow.Table.insert(%{item: "Rent", cost: "1000.00"}, id: "rent"),
  Sheetshow.Table.insert(%{item: "Food", cost: "400.00"}, id: "food")
]

{:ok, workbook} =
  Sheetshow.run(
    Sheetshow.Table.create(table) ++
      Sheetshow.Table.plan!(inserts, Sheetshow.Table.empty(table)),
    workbook
  )
```

The cycle for an existing table is **read → change → refresh → plan → run**:

```elixir
{:ok, snapshot} = Sheetshow.Table.read(table, workbook)

changes = [
  Sheetshow.Table.update("food", %{cost: "420.00", paid: true}),
  Sheetshow.Table.delete("rent")
]

{:ok, snapshot} = Sheetshow.Table.refresh(snapshot, workbook)
{:ok, workbook} = Sheetshow.run(Sheetshow.Table.plan!(changes, snapshot), workbook)

{:ok, snapshot} = Sheetshow.Table.read(table, workbook)
[%{id: "food", record: %{cost: "420.00", paid: true}}] = Sheetshow.Table.live(snapshot)
```

Row 7 *is* the record here, so position is load bearing and a snapshot goes
stale. Changes name rows by **id**, never by position, which is what lets
`refresh/2`, one read of the header and the id column, correct the positions
and leave the changes you are holding still valid. An update writes only the
columns it names plus the row's id, so a column someone else was editing is left
alone. On Google a `Table` is still last-write-wins in the gap after the refresh;
if that is not acceptable, use a `Log`, or a store that promises
`conditional_write`.

## Delete a row, and mean it

```elixir
%Sheetshow.Table.Change{hard: false} = Sheetshow.Table.delete("rent")   # a flag; nothing moves
%Sheetshow.Table.Change{hard: true} = Sheetshow.Table.delete("rent", hard: true)   # the row itself
%Sheetshow.Table.Change{action: :restore} = Sheetshow.Table.restore("rent")   # undo a soft delete

[%Sheetshow.Op.DeleteRows{rows: 1..1}] = Sheetshow.Table.compact(snapshot)   # every tombstone, for good
```

Soft is the default, and not out of timidity: a soft delete is one cell and
moves nothing, so a plan aimed at a row that has since shifted leaves a flag in
the wrong place rather than destroying a record. It is also the only safe delete
on `.xlsx`, where charts, defined names and pivot sources are anchored to
addresses that nothing here will fix when rows move.

`Sheetshow.Table.live/1` is the live rows; `snapshot.rows` is all of them,
tombstones included.

## Stay inside the quota, and back off when you do not

```elixir
defmodule Backoff do
  def run(plan, workbook, attempt \\ 0) do
    case Sheetshow.run(plan, workbook) do
      {:error, %Sheetshow.Error{reason: :rate_limited, details: details}} when attempt < 5 ->
        wait = details[:retry_after] || 2 ** attempt
        Process.sleep(wait * 1000)
        run(plan, workbook, attempt + 1)

      answer ->
        answer
    end
  end
end

{:ok, workbook} = Backoff.run([], workbook)
```

One request is one unit however many ops it carries, so batching is the only
lever, and `:rate_limited` is a reason of its own so a backoff can be written
without matching on error text. Retries are yours rather than the library's
because only you know whether the write is safe to repeat, and an append is.
The numbers are in [What Sheetshow Can Promise](guarantees.md).

## Keep a token alive in a long-running process

```elixir
defmodule Tokens do
  def ready(%Sheetshow.Workbook{ref: %Sheetshow.Client{} = client} = workbook) do
    if Sheetshow.Client.ready?(client, DateTime.add(DateTime.utc_now(), 60)) do
      {:ok, workbook}
    else
      Sheetshow.authenticate(workbook)
    end
  end

  # A backend with no token to keep alive is always ready.
  def ready(%Sheetshow.Workbook{} = workbook), do: {:ok, workbook}
end

{:ok, workbook} = Tokens.ready(workbook)
```

Sheetshow holds no process and caches nothing, so the workbook is a value your
application keeps and refreshes when it decides to. `ready?/2` takes the moment
to judge against, which is how you choose a margin: a minute, above, so a token
about to expire is replaced before a long batch rather than during it.

## Test spreadsheet logic without a network

```elixir
costs_cells = fn costs ->
  Sheetshow.stack([
    Sheetshow.row(["Item", "Cost"], style: %{bold: true}),
    Sheetshow.records(costs, [:item, :cost])
  ])
  |> Sheetshow.put_sheet("Costs")
end

sample = [%{item: "Rent", cost: 1000.0}, %{item: "Food", cost: 400.0}]

# The header goes on row 1 and a record on each row under it, asserted on the
# plan, with nothing carrying it out.
plan = Sheetshow.plan!(costs_cells.(sample), existing_sheets: ["Costs"])

["Costs!A1:B1", "Costs!A2:B2", "Costs!A3:B3"] =
  Enum.map(plan, &Sheetshow.Range.to_a1(Sheetshow.Op.PutCells.range(&1)))

# And carrying the plan out puts the values there, on a spreadsheet in a map.
{:ok, memory} = Sheetshow.connect(Sheetshow.Workbook.memory(["Costs"]))
{:ok, memory} = Sheetshow.run(plan, memory)

{:ok, [["Item", "Cost"], ["Rent", 1000.0], ["Food", 400.0]]} = Sheetshow.read_rows("Costs", memory)
```

Two levels, and both are worth having; in a test module each pattern match
above is an `assert`. A plan is a value, so most spreadsheet logic can be
asserted on without anything carrying it out. When you want the result rather
than the instructions, `Sheetshow.Workbook.memory/1` is a whole spreadsheet in a
map that refuses what Google refuses: the library's own test double, and the
executable definition of what an op means. It evaluates no formulas, which
is the one thing you still need a real spreadsheet for.
