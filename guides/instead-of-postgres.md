# Google Sheets Instead of Postgres

> Half serious. Everything below is true and the numbers are real; whether to
> run *your* data on it is your call, and you had better know what you are doing.
> The name of the library is the rest of the disclaimer.

Everyone agrees that using a spreadsheet as a database is a bad idea, and almost
nobody can say precisely which part is bad. That vagueness is where the bad
decisions live: both the decision to do it, and the decision to spend six weeks
not doing it. So we make the case properly here, for the one application it
fits: small, internal, and read or edited by people who are not us. That is, the
application we were going to stand a Postgres up for anyway, and then apologise
for the admin panel.

The Sheetshow snippets on this page are run by the test suite, in order, against
the in-memory and the xlsx backends, so they do what they say. The Ecto snippets
are there for comparison and are not. If you would rather start from the
beginning, the [Google quick start](quick-start-google.md) connects a
spreadsheet first and explains itself as it goes.

## The Part That Is Not a Joke

Consider what most internal applications actually are: an admin interface with
a database behind it. The database is not the hard part. The hard part is that
somebody in finance needs to see the rows, sort them, fix a typo, add a note
explaining why a figure looks wrong, and send the result to somebody else, and
`psql` does none of that, so we build it. Tables, filters, pagination, a form,
validation, an audit trail, a CSV export, a permissions model. Six weeks later
it is worse than Excel. Everyone knows this. Nobody says it in the planning
meeting.

A spreadsheet is that interface, already built, already familiar, already
administered by whoever administers our Google Workspace. The question is
whether the thing behind it can be made to behave enough like a database to
carry the application too. For a certain size and shape of application, we
think it can.

## Feature for Feature

| Postgres | Google Sheets |
| --- | --- |
| Schema migration | Type a new header. The library reads columns by name, so it keeps working. |
| Admin interface | The database. |
| Audit log | Version history, per cell, with the editor's name on it. |
| Point-in-time recovery | Version history again. Free, on by default, and we have already tested the restore because we have used Undo. |
| Row-level security | Protected ranges and sheet-level permissions. |
| Access control | Drive sharing, which the IT department already audits. |
| Reporting / BI | `QUERY()`, pivot tables, charts. The BI stack is a menu item. |
| Materialized view | A formula. It refreshes itself. There is no job to schedule and no staleness to monitor. |
| Connection pooling | There are no connections. |
| Read replica | Send someone the link. |
| `EXPLAIN ANALYZE` | Vibes. |
| Indexes | None. Fold in Elixir; see below. |
| Joins | None. `Enum`, or `VLOOKUP` if we are feeling native. |
| Foreign keys | A convention, and the hope that everybody honours it. |
| `VACUUM` | `Sheetshow.Table.compact/1`, or somebody deleting the blank rows at the bottom on a Friday afternoon. |
| Connection string | A URL, which somebody has already pasted into a Slack channel. |
| Downtime | Google's. The whole building knows before our monitoring does. |
| Backups | Somebody else's problem, for once genuinely. |

Note that the right-hand column is not a list of compromises. Six of those rows
are things Postgres does not give us at all, and that we were going to build.

## ACID, Honestly

**Atomicity: yes.** A plan compiles to one `batchUpdate`, and Google applies it
whole or not at all. Five hundred cells across four tabs land together or none
of them do. This is a real transaction boundary, and it is the one most people
assume is missing.

**Consistency: yes, at the edge.** `Sheetshow.Schema.encode/2` is strict: a
wrong type or an unknown column is refused before the request is built. What it
cannot do is stop a human typing `twelve` into a number column, which is why
reads are lenient and hand back a per-field error instead of failing the row.

**Isolation: no. None. Not a little.** There is no conditional write in the
Sheets API: no ETag, no `If-Match`, no revision precondition on `batchUpdate`.
The gap between reading a row and writing it back is unguarded, and two writers
in that gap produce last-write-wins. This is the one that matters, and the
storage engine further down is chosen to route around it.

**Durability: Google's.** Which, if we are honest about the single
unreplicated instance some of us have been running, is an upgrade.

Three out of four, then. The missing one is the one we have all been running at
`READ COMMITTED` and thinking about twice a year. The badge at the bottom of the
README reads `acid: :free`, which is also what they print on archival paper,
and it is meant the same way: it will last for centuries, and it does nothing
whatever to stop two people writing on the same line.

## CRUD, Side by Side

Suppose that we are keeping an expenses table. We show each operation in Ecto
first, so that we can see what we are giving up, and then in Sheetshow, so that
we can see what we are getting, which is mostly fewer files. The Sheetshow half
runs unchanged against Google, an `.xlsx` file or the in-memory backend;
`workbook` is whichever we connected, and the [cookbook](cookbook.md) shows all
three.

### Migration

In Ecto, a migration and a schema:

<!-- guide-test: skip -->
```elixir
# priv/repo/migrations/20260914000000_create_expenses.exs
defmodule App.Repo.Migrations.CreateExpenses do
  use Ecto.Migration

  def change do
    create table(:expenses) do
      add :item, :string, null: false
      add :cost, :decimal, null: false
      add :due, :date
      add :paid, :boolean, default: false
    end
  end
end

# lib/app/expense.ex
defmodule App.Expense do
  use Ecto.Schema

  schema "expenses" do
    field :item, :string
    field :cost, :decimal
    field :due, :date
    field :paid, :boolean, default: false
  end
end
```

In Sheetshow, the schema is the migration:

```elixir
table =
  Sheetshow.Table.new("expenses", item: :string, cost: :decimal, due: :date, paid: :boolean)

{:ok, workbook} = Sheetshow.run(Sheetshow.Table.create(table), workbook)
```

There is no directory of migrations because there is nothing to replay: the
tab's header *is* the current schema, and a read finds columns by name. Nobody
has ever asked for `mix ecto.rollback` on a spreadsheet, because the rollback is
called Undo and it has a keyboard shortcut.

Adding a column later is a header cell. Either a person types `note` in the
next empty header cell (which they were going to do anyway, so we may as well
call it a migration), or we extend the schema and write the header again:

```elixir
table = Sheetshow.Table.new("expenses", table.schema ++ [note: :string])

{:ok, workbook} = table |> Sheetshow.Table.header() |> Sheetshow.plan!() |> Sheetshow.run(workbook)
```

In contrast, Ecto wants another file:

<!-- guide-test: skip -->
```elixir
alter table(:expenses) do
  add :note, :string
end
```

Rows written before the column existed read back with `note: nil`, which is
what the migration's `NULL`s would have been.

### Insert

In Ecto:

<!-- guide-test: skip -->
```elixir
Repo.insert!(%App.Expense{item: "Rent", cost: Decimal.new("1000.00"), due: ~D[2026-10-01]})
Repo.insert!(%App.Expense{item: "Food", cost: Decimal.new("400.00"), due: ~D[2026-10-05]})
```

In Sheetshow:

```elixir
inserts = [
  Sheetshow.Table.insert(%{item: "Rent", cost: "1000.00", due: ~D[2026-10-01], paid: false}, id: "rent"),
  Sheetshow.Table.insert(%{item: "Food", cost: "400.00", due: ~D[2026-10-05], paid: false}, id: "food")
]

{:ok, snapshot} = Sheetshow.Table.read(table, workbook)
{:ok, workbook} = inserts |> Sheetshow.Table.plan!(snapshot) |> Sheetshow.run(workbook)
```

Two rows are one request, and so are two thousand. Note that an insert is an
append, which Google resolves against the last row at the moment it applies it,
so a plan of nothing but inserts is safe against a snapshot of any age,
including `Sheetshow.Table.empty/1`, which is how a tab is created and filled in
a single request:

```elixir
plan = Sheetshow.Table.create(table) ++ Sheetshow.Table.plan!(inserts, Sheetshow.Table.empty(table))
```

Ids are ours or the library's: leave `:id` out and we get a `Sheetshow.ULID`,
which sorts by time and looks enough like a code that nobody will be tempted to
retype it. `:decimal` is a string on both sides, so `Decimal.to_string/1` in and
`Decimal.new/1` out is the whole of the integration, and no double ever touches
the money.

### Read

In Ecto:

<!-- guide-test: skip -->
```elixir
Repo.all(from e in App.Expense, where: e.paid == false, order_by: e.due)
Repo.get(App.Expense, id)
```

In Sheetshow:

```elixir
{:ok, snapshot} = Sheetshow.Table.read(table, workbook)

unpaid =
  snapshot
  |> Sheetshow.Table.live()
  |> Enum.filter(&(&1.record.paid == false))
  |> Enum.sort_by(& &1.record.due, Date)

{:ok, rent} = Sheetshow.Table.fetch(snapshot, "rent")
```

One read, the whole tab, and everything after it is `Enum` over maps the schema
has already cast. There is no query planner, which is restful. A hundred
thousand rows fold in memory faster than the round trip that fetched them; the
index is the whole tab, and it is always in cache, because it is the cache.

Each row knows the sheet row it came from (`rent.row`) and carries `errors` for
any cell a person left in a state the column did not expect: `nil` in the
field and an `%Sheetshow.Error{}` beside it, rather than a failed read.

### Update

In Ecto:

<!-- guide-test: skip -->
```elixir
rent |> Ecto.Changeset.change(paid: true) |> Repo.update!()
```

In Sheetshow:

```elixir
changes = [Sheetshow.Table.update("rent", %{paid: true})]

{:ok, snapshot} = Sheetshow.Table.refresh(snapshot, workbook)
{:ok, workbook} = changes |> Sheetshow.Table.plan!(snapshot) |> Sheetshow.run(workbook)
```

An update writes only the columns it names (plus the row's id, so a write that
landed on the wrong row shows up as a repeated id at the next read), and it
names its row by id, never by position. `refresh/2` is one small read of the id
column that finds every row where it is *now*, so a row somebody inserted by
hand above ours does not make us overwrite the wrong one. Three requests for the
cycle, or two if we skip the refresh and know why. Skip it without knowing why,
and the library's name stops being a joke and starts being a description.

### Delete

In Ecto:

<!-- guide-test: skip -->
```elixir
Repo.delete!(rent)
```

In Sheetshow, four ways, of which the first is the default:

```elixir
Sheetshow.Table.delete("food")                # sets the deleted flag; nothing moves
Sheetshow.Table.delete("food", hard: true)    # takes the row out; rows below shift up
Sheetshow.Table.restore("food")               # undoes a soft delete
Sheetshow.Table.compact(snapshot)             # the plan that hard-deletes every tombstone
```

Soft is the default, and not out of timidity: a soft delete is one cell and
moves nothing, so a plan aimed at a row that has since shifted leaves a flag in
the wrong place instead of destroying a record. `Sheetshow.Table.live/1` hides
tombstones; `snapshot.rows` shows them, for the people who want to know who did
it, and Sheets' own version history shows *which* person, which is more than
`DELETE` ever told anyone.

### The Same Thing, as a Log

`Sheetshow.Table` is the model people expect from a spreadsheet, and the model
Google gives no isolation for. `Sheetshow.Log` is the other engine: every write
is a new row at the bottom, and the state is the fold.

```elixir
log = Sheetshow.Log.new("expenses_log", item: :string, cost: :decimal, due: :date, paid: :boolean)

rent = Sheetshow.Log.Event.new(%{item: "Rent", cost: "1000.00", due: ~D[2026-10-01], paid: false})
food = Sheetshow.Log.Event.new(%{item: "Food", cost: "400.00", due: ~D[2026-10-05], paid: false})

{:ok, workbook} = Sheetshow.run(Sheetshow.Log.create(log) ++ Sheetshow.Log.plan!([rent, food], log), workbook)

later = [Sheetshow.Log.Event.put(rent, %{paid: true}), Sheetshow.Log.Event.delete(food)]
{:ok, workbook} = Sheetshow.run(Sheetshow.Log.plan!(later, log), workbook)

{:ok, events} = Sheetshow.Log.read(log, workbook)
state = Sheetshow.Log.fold(events)
```

An update is the same id appended again; a delete is the same id with a flag;
and `fold/1` gives the latest event per id with the tombstoned ones gone.
Because Google resolves an append server-side, two processes appending at once
cannot land on each other, and a batch that failed with a transport error can
be sent again, since the duplicate ids fold away. That is the lost-update
problem the missing isolation would have cost us, routed around rather than
solved. An
append-only log with a fold is, not coincidentally, how several real databases
work; they just tend not to keep the log on a tab called `expenses_log` where
finance can see it.

**The rule: more than one writer, use the Log. One writer, either.** Most
internal tools have one writer, and it is a `cron` job. The rest of the
concurrency story is in [What Sheetshow Can Promise](guarantees.md).

## Where It Fits

Note the asymmetry in what follows: the first two lists want every line to hold,
and the third wants only one.

This **may be a good idea** when all of the following hold:

- the data is small: thousands of rows, maybe tens of thousands, well inside
  the ten-million-cell ceiling and well inside a person's patience for
  scrolling;
- people who are not developers need to read it, sort it, fix it and comment on
  it, and would otherwise be asking us for CSVs;
- there is one writer, or every writer appends;
- nothing waits on it in a hot path; and
- the organisation already lives in Google Workspace, so sharing and version
  history come for free.

The expenses tracker, the config table, the rota, the list of things five
colleagues keep asking us to change. None of these has ever needed a connection
pool. All of them have needed a column that somebody added on a Tuesday.

It **may be a semi-decent idea** when:

- there are a few writers, but we can make them all `Log` appends;
- the data will grow past a hundred thousand rows, but we can archive by tab or
  by spreadsheet;
- a latency of a few hundred milliseconds is fine, but we want a cache in front
  for reads; or
- we are prototyping and want the admin UI now and the real database later,
  since the `Log`'s fold and the `Table`'s snapshot both port to a real table
  without much thought.

This is the band where the name of the library starts earning its keep, and
where we should be able to say out loud which of the gotchas below we are
choosing.

It is **definitely a bad idea** when any of the following is true:

- the data is about people in a way that a leaked link would matter, because
  sharing is a URL and a permissions model built for documents;
- money moves on it, because a lost update is a payment that happened twice or
  not at all;
- more than a handful of writers update rows in place;
- anything about it is regulated, because the auditor's word will be "no";
- it has to answer in under a hundred milliseconds;
- it is over a million rows or heading there; or
- we need constraints the sheet cannot enforce (uniqueness, foreign keys,
  `NOT NULL`) and cannot afford to discover a violation at read time.

If any of those is us, the show is over: use Postgres. It is very good. This
guide has been assuming we knew that.

## Gotchas

The things that are true of a spreadsheet and not of a database, in the order
they will surprise us.

- **The quota, or where the sheet hits the fan.** Sixty reads and sixty writes
  a minute per user, refilled every minute, one request per unit however much
  it carries, and a 429 when we go over. Batching is the only lever. A loop
  that writes a row at a time is unusable; a plan of five hundred rows is one
  request.
- **Sheets coerces what people type.** `00123` becomes `123`, `1e3` becomes
  `1000`, `3/4` becomes a date, a phone number loses its leading zero, and
  `TRUE` typed into a text column becomes a boolean. `Sheetshow.Schema.cast/2`
  is lenient for exactly this reason and flags what it cannot read, but a value
  Sheets has already rewritten is gone. The library writes a string as a string,
  so `"00123"` survives when our code writes it; for the cells people type
  into, format the column as plain text first.
- **Someone will sort the tab.** They will do it to help. A `Table` finds its
  rows again by id (`refresh/2`), so a sort costs us a refresh. A `Log` read
  `after: cursor` answers `:moved` and wants a whole read. A `Log` sorted by a
  human is still a log, since the fold does not care about order, but the view
  tab's order is the id's, not the write's.
- **Someone will rename a header or a tab.** A renamed column is
  `:missing_column`, loudly, rather than a silent read of the neighbour. A
  renamed tab is `:unknown_sheet`. Protect the header row and the tab name.
- **Someone will delete a row.** By hand, below our cursor, and nothing will
  tell us. Soft delete exists so that at least our own code never does this;
  for the people, there is protecting the range, which is a suggestion with a
  dialog box.
- **`deleted` is a column people can see.** They will ask what it is, and one of
  them will type into it. It reads as `false` if they type something a boolean
  cannot be, and flags the row, which is the kindest thing the library could
  think of to do.
- **A formula is a value on the way in and a result on the way out.**
  `Sheetshow.read_rows/2` gives us what a formula worked out to, and a formula
  error as text we cannot tell from someone typing `#DIV/0!`;
  `Sheetshow.read_cells/2` gives us the formula. Do not store a formula in a
  column the schema owns.
- **Dates are numbers.** A `Date` is a serial number with a number format on
  it. Write dates through the library and they come back as dates; a person
  pasting `2026-10-01` gets whatever their locale decides, and a person pasting
  `10/01/2026` gets one of two dates.
- **Floats.** An integer above 2^53 does not survive a double, and `:decimal`
  is a string precisely so that money does not become `1000.0000000001`.
- **Time zones.** A `DateTime` is written as its wall-clock time with the zone
  dropped, and comes back a `NaiveDateTime`. Store UTC, or store the zone.
- **A refresh token from an app in Testing dies in seven days.** It arrives as
  the same `invalid_grant` a revoked token does. Publish the app, or use a
  service account; [Setting Up Google](google-setup.md) walks through both.
- **Version history is per cell, but restore is the whole spreadsheet.** We can
  see who changed what; putting one cell back is a copy and paste, and putting
  the file back takes every tab with it.
- **Performance falls off long before the hard limit.** Ten million cells is
  the ceiling; people report the spreadsheet itself getting slow with formulas
  at around a tenth of that, and nobody opening a 500,000-row tab in a browser
  will thank us. Our code does not care, but the whole point was that a person
  could open it.

## Precedent

People have done this before, at scales that should worry us, and the walls
they hit are the same walls.

**Levels.fyi ran on Google Sheets for about two years**, to one or two million
unique visitors a month. Submissions came in through Google Forms, a Lambda
appended them to a sheet, and reads were served from JSON the Lambda wrote to
S3 behind CloudFront: every salary, over a hundred thousand of them, in one
JSON file the browser downloaded. The walls: the JSON grew to several
megabytes and the Lambda started timing out; "Google Sheets API rate limiting is
pretty strict for write paths"; anyone could scrape the whole dataset in one
request; and there was no way to run analytics without SQL. They moved to
Postgres by writing to both and cutting over. Two years of a real business on
a spreadsheet is a strong existence proof, and the reasons they left are the
"bad idea" list above. They ran what this library is named after, on purpose,
at scale, and it worked right up until it did not, which is the most honest
review a storage engine can get.
([Levels.fyi](https://www.levels.fyi/blog/scaling-to-millions-with-google-sheets.html))

**Nomad List started as a crowdsourced Google Sheet** of cities and their cost
of living, internet speed and safety, in 2014, and was a website within weeks:
the spreadsheet was the fastest way to find out whether anybody cared, and the
product was what got built once they did.
([levels.io](https://levels.io/nomad-list-founder))

**Glide and AppSheet, the two no-code platforms that made Sheets-as-a-backend
mainstream, both built their own databases.** Glide capped spreadsheet-backed
apps at 25,000 rows across all tables and introduced Big Tables, its own store
holding ten million rows, because "many businesses have needs that surpass our
current 25,000-row limit". Google's own AppSheet added a native database and
recommends it over Sheets for "performance improvements for both app creator
and app user as compared to other data sources". When the two companies whose
business was Sheets-as-a-database both decide the database part should not be
Sheets, that is the ceiling being drawn for us.
([Glide](https://www.glideapps.com/blog/introducing-big-tables),
[AppSheet](https://support.google.com/appsheet/answer/12631542))

**Public Health England lost 15,841 positive COVID-19 test results** between
25 September and 2 October 2020 because the pipeline put results into Excel's
old `.xls` format, which stops at 65,536 rows; the rows past the limit were
silently dropped, and as many as 48,000 contacts were not traced. Not Google
Sheets, and not an API, but the same category of failure: a row limit nobody
had written down, met in production, with no error.
([The Register](https://www.theregister.com/2020/10/05/excel_england_coronavirus_contact_error/))

The pattern across all of them is the same. The spreadsheet was the right call
at the start, for the reasons in the table at the top; it stopped being the
right call at a size or a write rate that was knowable in advance; and the ones
who did well are the ones who knew where that line was and had arranged to be
able to cross it. For the record, Google Sheets' own limits are ten million
cells (up from five million in March 2022), 18,278 columns and 50,000
characters in a cell, and the API's are sixty reads and sixty writes a minute
per user with no daily cap
([Google](https://workspaceupdates.googleblog.com/2022/03/ten-million-cells-google-sheets.html),
[Sheets API](https://developers.google.com/workspace/sheets/api/limits)).
Write yours down before you start.

## Leaving

When we do outgrow it, the shapes port. A `Table` snapshot is a list of maps
with ids, which is a `COPY`. A `Log` is an event table, and `fold/1` is the
query we already know how to write in SQL. Keep the ids, which are the primary
keys, and the migration is one script that reads the tab whole and inserts it,
which is a thing this library makes one request. Leaving a spreadsheet for
Postgres is the one migration everybody in the room will agree was a good idea,
so enjoy the meeting; there will not be another like it.

Everything else, the internal tool, the config table, the tracker, the rota,
is a spreadsheet. It has always been a spreadsheet. We were going to write four
thousand lines of code to hide that from ourselves. There is no shame in it.
There is some shame in the name of the library, and that is on purpose.
