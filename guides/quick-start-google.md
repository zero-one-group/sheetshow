# Quick Start: Google Sheets

Sheetshow treats a spreadsheet as a list of cells, turns what we want done to it
into a plan, and carries the plan out with one function. This page walks through
the whole library (cells, the two reads, a log and a table) against a real
Google spreadsheet, and shows the two things only Google can do: work a formula
out, and keep a view tab current. The same tour against an `.xlsx` file, with no
account and no network, is [Quick Start: An .xlsx File](quick-start-xlsx.md);
the code is the same apart from the first block, and the two pages point out
where the backends differ.

Every `elixir` snippet on this page is run by the test suite, in order, in one
set of bindings: offline against the in-memory backend, and against a real
spreadsheet when the integration tests run. The pattern matches are the
assertions.

## A Spreadsheet to Talk To

We need a service account and a spreadsheet shared with it, as Editor, exactly
as we would share it with a person. [Setting Up Google](google-setup.md) walks
through making both; it takes about ten minutes and no billing. With the key
file in hand, a workbook is the spreadsheet's id, the long string in its URL,
and the credentials:

<!-- guide-test: skip -->
```elixir
account = Sheetshow.ServiceAccount.from_file!("service-account.json")

{:ok, workbook} =
  "1AbC...the id from the URL"
  |> Sheetshow.Workbook.google(credentials: account)
  |> Sheetshow.connect()
```

`Sheetshow.connect/1` trades the credentials for a token and asks the
spreadsheet which sheets it has, in two requests. It is the one setup call,
once per workbook rather than once per operation. Sheetshow keeps no process
and no cache: the workbook is a value, and where it lives is our application's
business.

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
spreadsheet has not got one:

```elixir
plan = Sheetshow.plan!(cells, existing_sheets: Sheetshow.Workbook.titles(workbook))

[%Sheetshow.Op.AddSheet{title: "Costs"} | puts] = plan
5 = length(puts)
```

Five `Sheetshow.Op.PutCells` for five rows, because a `PutCells` is one run of
neighbouring cells on one row. Note that the dates were given a number format
nobody asked for, since a date is a number until a format says otherwise, and
the header's colour rode along with it.

`Sheetshow.run/2` is the only function in the library that writes anything. At
Google it is one `batchUpdate`, applied whole or not at all, and it costs one
unit of the quota however many ops it carries:

```elixir
{:ok, workbook} = Sheetshow.run(plan, workbook)

true = "Costs" in Sheetshow.Workbook.titles(workbook)
```

The workbook comes back knowing the tab the plan made, so the next plan needs
no fresh metadata.

## The Two Reads

There are two ways to read, and they are not the same read. `Sheetshow.read_rows/2`
asks the values endpoint for what the cells work out to: the cheap read, about
a twelfth of the bytes, and the one the database layer below uses:

```elixir
{:ok, rows} = Sheetshow.read_rows("Costs", workbook)

[["Item", "Cost", "Due"], ["Rent", 1000, _due] | _rest] = rows
```

Note the `_due`: the values endpoint hands a date back as the serial number it
is, `46296` for the first of October 2026. That is what a `Sheetshow.Schema`
expects, and why a stored date needs a schema to say it is one.

`Sheetshow.read_cells/2` asks for cells: what was entered, how it looks, and
what Sheets made of it in `meta`. A formula reads back as the formula, so a
cell we read is a cell we can write again, and here, because Google works
formulas out, the answer is in `meta.effective` and the text Sheets showed is
in `meta.formatted`:

```elixir
{:ok, [total]} = Sheetshow.read_cells("Costs!B5", workbook)

{:formula, "=SUM(B2:B4)"} = total.value
%{bold: true} = total.style
```

```elixir
if Sheetshow.Backend.supports?(workbook, :evaluates_formulas) do
  %{effective: 1450, formatted: "1450"} = total.meta
end
```

That `if` is the one honest thing to write: the in-memory backend the test
suite runs this page against evaluates nothing, and neither does a file. The
backend says what it can do rather than leaving us to find out, which is what
`Sheetshow.Backend.capabilities/1` is for:

```elixir
true = Sheetshow.Backend.supports?(workbook, :atomic_batch)
true = Sheetshow.Backend.supports?(workbook, :server_side_append)
false = Sheetshow.Backend.supports?(workbook, :conditional_write)
```

The second is the promise the log below rests on. The third is the one Google
cannot make, and [What Sheetshow Can Promise](guarantees.md) is about living
with that.

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
write safe to retry: the same id appended twice folds to one row. It is also
what makes a log safe for several writers at once, since Google resolves an
append against the last row at the moment it applies it, so two processes
appending cannot land on each other.

```elixir
[rent, _food, bus] = events
later = [Sheetshow.Log.Event.put(rent, %{cost: "1100.00"}), Sheetshow.Log.Event.delete(bus)]

{:ok, workbook} = Sheetshow.run(Sheetshow.Log.plan!(later, log), workbook)
```

To read only what is new, we hand back the last event we hold. A cursor is an
event a read gave us (its `row` is what makes it one), and folding in batches
gives the same answer as folding the lot. At Google the header and the rows
below the cursor come in one request:

```elixir
{:ok, new} = Sheetshow.Log.read(log, workbook, after: List.last(events))
[{"Rent", false}, {"Bus", true}] = Enum.map(new, &{&1.record.item, &1.deleted})

state = Sheetshow.Log.fold(Sheetshow.Log.fold(events) ++ new)
[{"Rent", "1100.00"}, {"Food", "400.00"}] = Enum.map(state, &{&1.record.item, &1.record.cost})

{:ok, everything} = Sheetshow.Log.read(log, workbook)
^state = Sheetshow.Log.fold(everything)
```

The latest event per id wins and the tombstoned id drops out: that one rule is
what gives a log updates, deletes and retry-safety at once.

## The View Tab

A person looking at the spreadsheet does not want the history; they want the
state. `Sheetshow.Log.view/2` is a second tab holding one formula that works
`fold/1` out inside Sheets, so it stays current as rows are appended and
nothing has to be rewritten:

```elixir
view = Sheetshow.Log.view(log, "expenses now")

{:ok, workbook} =
  view
  |> Sheetshow.plan!(existing_sheets: Sheetshow.Workbook.titles(workbook))
  |> Sheetshow.run(workbook)
```

```elixir
if Sheetshow.Backend.supports?(workbook, :evaluates_formulas) do
  {:ok, [_header | shown]} = Sheetshow.read_rows("expenses now", workbook)

  ids = state |> Enum.map(& &1.id) |> Enum.sort()
  ^ids = shown |> Enum.map(&List.first/1) |> Enum.sort()
end
```

The formula turns on `SORTN` and `LET`, which Excel has not got, so the view tab
is Google's alone; the xlsx page folds in Elixir and writes plain rows instead.
The tab sorts by id, and a `Sheetshow.ULID` sorts by the moment it was made, so
the rows come out in the order they were written.

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
suppose that somebody else, a person in the browser or another process, takes
a row out from under us:

```elixir
{:ok, workbook} =
  Sheetshow.run(Sheetshow.Table.plan!([Sheetshow.Table.delete("rent", hard: true)], snapshot), workbook)
```

The snapshot in hand is now wrong about where things sit. The changes we want to
make are not, because a change names its row by id and never by position, so
`Sheetshow.Table.refresh/2`, one small read of the header and the id column,
can find the rows again, and the same changes plan against the fresh positions:

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

A table's whole cycle is read, change, refresh, plan, run: three requests, or
two without the refresh, and we can count them at the call site. Nothing closes
the gap between the refresh and the write, because Google has nothing that
could; the page on [what Sheetshow can promise](guarantees.md) says what to do
about that.

## Tidying Up

Everything above was pure functions building values, and nine calls to
`Sheetshow.run/2`. The four tabs can go the way they came, in one more:

```elixir
made = ["Costs", "expenses", "expenses log", "expenses now"]

{:ok, workbook} = Sheetshow.run(Enum.map(made, &Sheetshow.Op.DeleteSheet.new/1), workbook)

[] = Enum.filter(Sheetshow.Workbook.titles(workbook), &(&1 in made))
```

## Where to Go Next

  * [Quick Start: An .xlsx File](quick-start-xlsx.md). The same tour against a
    file, and what a file cannot promise.
  * [Setting Up Google](google-setup.md). The service account, the shared
    spreadsheet, and user sign-in when a robot will not do.
  * [Cookbook](cookbook.md). Recipes for the things people actually do.
  * [What Sheetshow Can Promise](guarantees.md). Atomic batches, the missing
    conditional write, and the quota.
