<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
  <img src="assets/logo.svg" alt="#SHEETSHOW!" width="320">
</picture>

[![Hex.pm](https://img.shields.io/hexpm/v/sheetshow.svg)](https://hex.pm/packages/sheetshow)
[![Docs](https://img.shields.io/badge/hex-docs-8e5ba6.svg)](https://hexdocs.pm/sheetshow)
[![License](https://img.shields.io/hexpm/l/sheetshow.svg)](LICENSE)

Google Sheets from Elixir, as values. A spreadsheet is a collection of cells;
pure functions turn what you want into a plan, and one function at the edge of
your application carries the plan out. On top of that sits a small database, an
append-only log or a table of rows with ids, for the times a tab is the right
place to keep something. The same code runs against `.xlsx` files, on disk or on
a WebDAV server.

## Install

```elixir
def deps do
  [{:sheetshow, "~> 0.1.3"}]
end
```

No dependencies. Elixir 1.18 or later, for the built-in `JSON`; everything else
comes from OTP.

## The first thing that works

```elixir
costs = [%{item: "Rent", cost: 1000}, %{item: "Food", cost: 400}]

cells =
  Sheetshow.stack([
    Sheetshow.row(["Item", "Cost"], style: %{bold: true}),
    Sheetshow.records(costs, [:item, :cost])
  ])
  |> Sheetshow.put_sheet("Costs")

{:ok, account} = Sheetshow.ServiceAccount.from_file("service-account.json")
{:ok, workbook} = Sheetshow.connect(Sheetshow.Workbook.google(id, credentials: account))

cells
|> Sheetshow.plan!(existing_sheets: Sheetshow.Workbook.titles(workbook))
|> Sheetshow.run(workbook)
```

`plan!/2` builds a value; `run/2` is the only thing there that writes anything,
and it is one request whatever the plan holds. Swap `Workbook.google/2` for
`Workbook.xlsx("costs.xlsx", create: true)` and none of the rest changes.

The two quick starts walk the whole library end to end (cells, the two reads, a
log and a table) [against a Google spreadsheet](guides/quick-start-google.md)
and [against an `.xlsx` file](guides/quick-start-xlsx.md), which needs no account
and no network. Every snippet on both pages is run by the test suite.

## What this is

**Values until the edge.** Cells, plans, schemas, credentials and tokens are
structs and maps. Pure functions turn what you want into a plan; one function
carries the plan out. You test spreadsheet logic by asserting on plans, with
nothing mocked and nothing stubbed.

**No runtime ownership.** Sheetshow defines no GenServer, supervisor, registry,
pool or application callback module, and reads no configuration. Token caching,
retries, backoff and scheduling belong to your application, which is the only
thing that knows what they should be.

**No macros.** A schema is a keyword list you pass to functions. A query is
`Enum`. There is nothing to `use`.

**A database, with the caveats printed.** A plan is applied whole or not at
all; nothing between a read and a write is, because the Sheets API has no
conditional write, so the library makes re-reading cheap instead of pretending
the gap is closed. Where a backend cannot keep a promise it says so, in
`Sheetshow.Backend.capabilities/1`, rather than letting you find out later.
[What Sheetshow Can Promise](guides/guarantees.md) is the whole argument.

## What's in it

**Cells and plans.** Coordinates, inclusive ranges and A1 parsing; values
including formulas, dates and times; styles; and layout functions that build
rows, columns, tables and records and stack them next to and below each other.
`Sheetshow.plan/2` turns cells into ops, `run/2` carries them out, and `read_cells/2`
and `read_rows/2` are the two reads: cells with everything about them, or
plain rows at about a twelfth the bytes.

**A database on a tab.** `Sheetshow.Log` is append-only: an update is the same
id appended again, a delete is the same id with a flag, and `fold/1` turns the
history back into state. Because Google resolves an append server-side, several
writers need no compare-and-swap between them, and a failed write is safe to
retry, as long as it is retried before anything newer is written. `Sheetshow.Table` is the mutable one, where row 7 *is* the record: read a
snapshot, build changes that name rows by id, `refresh/2` to find them again,
then plan and run. Both share `Sheetshow.Schema`, which is a keyword list.

**Backends.** Google Sheets, an in-memory one that doubles as the test double,
and `.xlsx`, over a local file or over WebDAV, where the store gives you the
conditional write Google will not. Foreign workbooks survive a round trip:
charts, pivot tables, merged cells, conditional formatting and macros are copied
through untouched.

**Credentials.** Service accounts and user OAuth, both reduced to one token type
that nothing downstream can tell apart. `Sheetshow.OAuth` builds the consent URL
and reads the answer; running a loopback listener is your application's job, not
the library's.

**What it costs.** Google allows 60 reads and 60 writes a minute per user, and
one request is one unit however many ops it carries, so batching is the only
lever, and you can count a cycle's requests at the call site. The numbers are in
the [guide](guides/guarantees.md).

## Where to go next

[Setting Up Google](guides/google-setup.md) is the service account, the shared
spreadsheet, and user sign-in when a robot will not do. The
[cookbook](guides/cookbook.md) is recipes for the things people actually do, and
[Google Sheets instead of Postgres](guides/instead-of-postgres.md) is the case
for using a spreadsheet as the database, made properly, with the walls other
people hit. [What Sheetshow Can Promise](guides/guarantees.md) is the reference
for atomicity, the missing conditional write and the quota; the
[cheatsheet](guides/cheatsheet.cheatmd) is every public function on one page;
and [usage-rules.md](usage-rules.md) is the short set of rules that are not
guessable from the names, for an agent's context as much as a person's.

## Why this and not something else

[`google_api_sheets`](https://hex.pm/packages/google_api_sheets) is Google's own
client, generated from the API specification. It is complete and it is the right
answer when you want the Sheets API itself: everything is there, and so is every
concept Google has, expressed as generated structs.

[`elixir_google_spreadsheets`](https://hex.pm/packages/elixir_google_spreadsheets)
is the established convenience layer. It supervises a process per spreadsheet and
reads and writes a row at a time, `GSS.Spreadsheet.read_row(pid, 1)`, which is
a comfortable shape until the quota notices, since a row is a request.

Sheetshow is for the case where the spreadsheet is part of your application's
design rather than an export target: where you want the write to be a value you
can test, the request count to be something you decide rather than discover, and
a tab to be usable as a small database without giving up on knowing what it does
and does not guarantee. It owns no processes and takes no dependencies, and the
same cells go to an `.xlsx` file when the spreadsheet stops being the point.

If you want the full API surface, take Google's client. If you want a row at a
time and don't mind the process, take GSS. This is the third option.

## Development

```
mix check      # format, compile with warnings as errors, offline tests
mix check.all  # also the integration tests against a real spreadsheet
mix docs       # the documentation, as it appears on HexDocs

mix run dev/cheatsheet.exs --write   # regenerate guides/cheatsheet.cheatmd
```

The guides are run, not read: every `elixir` block in `guides/` is executed by
the tests, in order, and its pattern matches are the assertions. The cheatsheet
is generated from the compiled modules, and a test fails when it drifts.

`ex_doc` is the only entry in `deps`, and it is `only: :dev, runtime: false`:
nothing ships with Sheetshow, and nothing is loaded at runtime.

## How this was built

Claude (Anthropic) wrote the overwhelming majority of the code, the tests and the
documentation. The maintainer set the scope, made the design calls, ran every
gate and reviewed the result. That division is worth stating plainly rather than
leaving to be guessed at.

## License

Apache License 2.0. See `LICENSE`.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/badge-dark.svg">
  <img src="assets/badge.svg" alt="%Sheetshow{acid: :free, gsm: 80, sheets: 500, last_write: :wins}" width="400">
</picture>
