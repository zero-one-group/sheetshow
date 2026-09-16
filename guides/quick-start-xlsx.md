# Quick Start: An .xlsx File

Sheetshow treats a spreadsheet as a list of cells, turns what we want done to it
into a plan, and carries the plan out with one function. This page walks through
the whole library (cells, the two reads, a log and a table) against an `.xlsx`
file on disk, so there is nothing to sign up for and nothing on the network. The
same tour against a real Google spreadsheet is
[Quick Start: Google Sheets](quick-start-google.md); the code is the same apart
from the first block, and the two pages point out where the backends differ.

Every `elixir` snippet on this page is run by the test suite, in order, in one
set of bindings. The pattern matches are the assertions.

## A File to Write To

A workbook is a value that names a backend and whatever the backend needs to
find the spreadsheet. For a file, that is a path. `create: true` says a file
that is not there yet is an empty workbook we mean to write, rather than a
mistake:

```elixir
{:ok, workbook} =
  "costs.xlsx"
  |> Sheetshow.Workbook.xlsx(create: true)
  |> Sheetshow.connect()

["Sheet1"] = Sheetshow.Workbook.titles(workbook)
```

Nothing has been written yet. `Sheetshow.connect/1` learns which sheets the
workbook has, and a workbook a spreadsheet program will open needs at least one,
so an empty one comes with `Sheet1`.

## Cells, a Plan, One Write

Suppose that we keep a small list of monthly costs. The layout functions on
`Sheetshow` build cells from rows, columns and records and stack them below one
another; `put_sheet/2` says which tab they belong to:

```elixir
costs = [
  %{item: "Rent", cost: 1000, due: ~D[2026-10-01]},
  %{item: "Food", cost: 400, due: ~D[2026-10-05]},
  %{item: "Bus", cost: 50, due: ~D[2026-10-05]}
]

cells =
  Sheetshow.stack([
    Sheetshow.row(["Item", "Cost", "Due"], style: %{bold: true, background: "#EFEFEF"}),
    Sheetshow.records(costs, [:item, :cost, :due]),
    Sheetshow.row(["Total", {:formula, "=SUM(B2:B4)"}], style: %{bold: true})
  ])
  |> Sheetshow.put_sheet("Costs")

14 = length(cells)
```

`Sheetshow.plan/2` turns the cells into ops, the backend-neutral vocabulary of
what a backend is asked to do. Nothing has happened yet; a plan is a list of
structs that we can inspect, assert on in a test, or extend with `++`. Passing
`:existing_sheets` is what makes the plan add the `Costs` tab, since the
workbook has not got one:

```elixir
plan = Sheetshow.plan!(cells, existing_sheets: Sheetshow.Workbook.titles(workbook))

[%Sheetshow.Op.AddSheet{title: "Costs"} | puts] = plan
5 = length(puts)
```

Five `Sheetshow.Op.PutCells` for five rows, because a `PutCells` is one run of
neighbouring cells on one row. Note that the dates were given a number format
nobody asked for, since a date is a number until a format says otherwise, and
the header's colour rode along with it.

`Sheetshow.run/2` is the only function in the library that writes anything.
Against a file it reads the workbook, applies the plan and writes the file back,
whole or not at all:

```elixir
{:ok, workbook} = Sheetshow.run(plan, workbook)

["Costs", "Sheet1"] = Sheetshow.Workbook.titles(workbook)
true = File.exists?("costs.xlsx")
```

The file is now a real `.xlsx` that Excel or LibreOffice will open.

## The Two Reads

There are two ways to read, and they are not the same read. `Sheetshow.read_rows/2`
gives back rows of values: the cheap read, and the one the database layer
below uses:

```elixir
{:ok, rows} = Sheetshow.read_rows("Costs", workbook)

[
  ["Item", "Cost", "Due"],
  ["Rent", 1000, ~D[2026-10-01]],
  ["Food", 400, ~D[2026-10-05]],
  ["Bus", 50, ~D[2026-10-05]],
  ["Total", {:formula, "=SUM(B2:B4)"}, nil]
] = rows
```

`Sheetshow.read_cells/2` gives back cells: what was entered, how it looks, and
what the spreadsheet made of it in `meta`. A formula reads back as the formula,
so a cell we read is a cell we can write again:

```elixir
{:ok, [total]} = Sheetshow.read_cells("Costs!B5", workbook)

{:formula, "=SUM(B2:B4)"} = total.value
%{bold: true} = total.style
nil = total.meta[:effective]
```

That missing `meta.effective` is the first place a file differs from Google.
Nothing here evaluates anything: an `.xlsx` stores a formula and, at best, the
value the program that last saved it had worked out, and this file has never
been opened by one. The backend says so up front rather than leaving us to find
out:

```elixir
false = Sheetshow.Backend.supports?(workbook, :evaluates_formulas)
false = Sheetshow.Backend.supports?(workbook, :server_side_append)
false = Sheetshow.Backend.supports?(workbook, :conditional_write)
```

The other two promises are the ones that matter for a database on a file: an
append to a file is a rewrite of the file, and a local file cannot refuse a
write that would clobber somebody else's.
[What Sheetshow Can Promise](guarantees.md) explains both, and what a WebDAV
store adds.

## A Log: A Tab We Only Append To

A schema is a keyword list, with no macro, no compile step and no module to
define, and `Sheetshow.Log` is an append-only tab whose rows are events with ids:

```elixir
schema = [item: :string, cost: :decimal, due: :date, paid: :boolean]
log = Sheetshow.Log.new("expenses log", schema)

first = [
  Sheetshow.Log.Event.new(%{item: "Rent", cost: "1000.00", due: ~D[2026-10-01], paid: false}),
  Sheetshow.Log.Event.new(%{item: "Food", cost: "400.00", due: ~D[2026-10-05], paid: false}),
  Sheetshow.Log.Event.new(%{item: "Bus", cost: "50.00", due: ~D[2026-10-05], paid: true})
]

{:ok, workbook} =
  Sheetshow.run(Sheetshow.Log.create(log) ++ Sheetshow.Log.plan!(first, log), workbook)

{:ok, events} = Sheetshow.Log.read(log, workbook)
["Rent", "Food", "Bus"] = Enum.map(events, & &1.record.item)
```

Plans are lists, so the tab, its header and its first rows went in one write.
Note that `:decimal` is a string on both sides: `"1000.00"` stays `"1000.00"`,
and no double ever touches it.

An update is the same id appended again, and a delete is the same id with the
`deleted` flag set. Nothing is edited in place, which is what makes a failed
write safe to retry: the same id appended twice folds to one row.

```elixir
[rent, _food, bus] = events
later = [Sheetshow.Log.Event.put(rent, %{cost: "1100.00"}), Sheetshow.Log.Event.delete(bus)]

{:ok, workbook} = Sheetshow.run(Sheetshow.Log.plan!(later, log), workbook)
```

To read only what is new, we hand back the last event we hold. A cursor is an
event a read gave us (its `row` is what makes it one), and folding in batches
gives the same answer as folding the lot:

```elixir
{:ok, new} = Sheetshow.Log.read(log, workbook, after: List.last(events))
[{"Rent", false}, {"Bus", true}] = Enum.map(new, &{&1.record.item, &1.deleted})

state = Sheetshow.Log.fold(Sheetshow.Log.fold(events) ++ new)
[{"Rent", "1100.00"}, {"Food", "400.00"}] = Enum.map(state, &{&1.record.item, &1.record.cost})

{:ok, everything} = Sheetshow.Log.read(log, workbook)
^state = Sheetshow.Log.fold(everything)
```

The latest event per id wins and the tombstoned id drops out: that one rule is
what gives a log updates, deletes and retry-safety at once. On Google there is a
view tab that works the fold out inside the spreadsheet; it turns on `SORTN`,
which Excel has not got, so the Google page shows it and this one does not.

## A Table: Rows We Overwrite

`Sheetshow.Table` is the other model: row 7 *is* the record, and changing it
means writing over row 7. `Sheetshow.Table.empty/1` is the snapshot of a tab we
are making in the same breath, so the tab, its header and three rows go in one
request with nothing read first:

```elixir
table = Sheetshow.Table.new("expenses", schema)

inserts = [
  Sheetshow.Table.insert(%{item: "Rent", cost: "1000.00", due: ~D[2026-10-01], paid: false}, id: "rent"),
  Sheetshow.Table.insert(%{item: "Food", cost: "400.00", due: ~D[2026-10-05], paid: false}, id: "food"),
  Sheetshow.Table.insert(%{item: "Bus", cost: "50.00", due: ~D[2026-10-05], paid: true}, id: "bus")
]

{:ok, workbook} =
  Sheetshow.run(
    Sheetshow.Table.create(table) ++ Sheetshow.Table.plan!(inserts, Sheetshow.Table.empty(table)),
    workbook
  )

{:ok, snapshot} = Sheetshow.Table.read(table, workbook)
[{"rent", 1}, {"food", 2}, {"bus", 3}] = Enum.map(Sheetshow.Table.live(snapshot), &{&1.id, &1.row})
```

Each row knows the sheet row it came from, and that is what a write needs. Now
suppose that somebody else, a person with the file open or another process,
takes a row out from under us:

```elixir
{:ok, workbook} =
  Sheetshow.run(Sheetshow.Table.plan!([Sheetshow.Table.delete("rent", hard: true)], snapshot), workbook)
```

The snapshot in hand is now wrong about where things sit. The changes we want to
make are not, because a change names its row by id and never by position, so
`Sheetshow.Table.refresh/2` can find the rows again and the same changes plan
against the fresh positions:

```elixir
changes = [Sheetshow.Table.update("food", %{cost: "420.00", paid: true}), Sheetshow.Table.delete("bus")]

{:ok, snapshot} = Sheetshow.Table.refresh(snapshot, workbook)
[{"food", 1}, {"bus", 2}] = Enum.map(Sheetshow.Table.live(snapshot), &{&1.id, &1.row})

{:ok, workbook} = Sheetshow.run(Sheetshow.Table.plan!(changes, snapshot), workbook)
{:ok, snapshot} = Sheetshow.Table.read(table, workbook)

[%Sheetshow.Table.Row{id: "food", record: %{cost: "420.00", paid: true}}] = Sheetshow.Table.live(snapshot)
2 = length(snapshot.rows)
```

The update wrote only the columns it named. The delete was a soft one, a flag
rather than a hole, so the tombstone is still there and nothing under it moved,
which is why a plan aimed at an older snapshot cannot land on the wrong row.
`Sheetshow.Table.compact/1` is the sweep that really removes them:

```elixir
{:ok, workbook} = Sheetshow.run(Sheetshow.Table.compact(snapshot), workbook)
{:ok, snapshot} = Sheetshow.Table.read(table, workbook)

["food"] = Enum.map(snapshot.rows, & &1.id)
```

## The File, Afterwards

Everything above was pure functions building values, and eight calls to
`Sheetshow.run/2`. The `Sheet1` that came with the new workbook can go now that
it has company:

```elixir
{:ok, workbook} = Sheetshow.run([Sheetshow.Op.DeleteSheet.new("Sheet1")], workbook)

["Costs", "expenses", "expenses log"] = Sheetshow.Workbook.titles(workbook)
```

Open `costs.xlsx` in a spreadsheet program and the three tabs are there: the
costs with their bold header, the log with its history, and the table with one
live row. A file that already exists can be pointed at the same way, without
`create: true`, and anything in it Sheetshow does not model (charts, merged
cells, conditional formatting) survives a write untouched.

## Where to Go Next

  * [Quick Start: Google Sheets](quick-start-google.md). The same tour, against
    a real spreadsheet, with the two things only Google can do.
  * [Cookbook](cookbook.md). Recipes for the things people actually do.
  * [What Sheetshow Can Promise](guarantees.md). Atomic batches, the missing
    conditional write, and the quota.
