# Using Sheetshow

Sheetshow treats a Google spreadsheet as a list of cells: pure functions turn what we want into
a plan, and one function carries the plan out. The same code runs against an `.xlsx` file and
against an in-memory spreadsheet. This file is the short set of rules that are not guessable
from the function names, in the `usage_rules` convention, so that a consuming project can sync
it into an agent's context. The [cheatsheet](guides/cheatsheet.cheatmd) is every function on
one page.

## The Shape

**Cells → plan → run.** `Sheetshow.plan/2` turns cells into a list of ops and reaches nothing;
`Sheetshow.run/2` carries the plan out and is the only function in the library that writes.
One plan is one request, whatever it holds.

    cells = Sheetshow.row(["Item", "Cost"], sheet: "Costs")
    plan = Sheetshow.plan!(cells, existing_sheets: Sheetshow.Workbook.titles(workbook))
    {:ok, workbook} = Sheetshow.run(plan, workbook)

**`:existing_sheets` is what makes a plan add a tab.** Without it, a cell on a sheet the plan
has not been told about is written as if the sheet were there, and Google refuses. Pass the
workbook's titles, and the `AddSheet` rides in the same request as the first cells.

**Keep the workbook `run/2` gives back.** It knows the sheets the plan created, and on Google
it carries the token and any rotated refresh token. A workbook is a value; where it lives is
the application's business.

**Every function that can fail returns `{:ok, value} | {:error, %Sheetshow.Error{}}`**, and
has a `!` twin of the same arity that raises. Match on `error.reason`, an atom, never on the
message; `Sheetshow.Error`'s moduledoc lists every reason.

## Connecting

    account = Sheetshow.ServiceAccount.from_file!("service-account.json")
    {:ok, workbook} = id |> Sheetshow.Workbook.google(credentials: account) |> Sheetshow.connect()

    {:ok, workbook} = "costs.xlsx" |> Sheetshow.Workbook.xlsx(create: true) |> Sheetshow.connect()
    {:ok, workbook} = Sheetshow.Workbook.memory() |> Sheetshow.connect()

`Sheetshow.connect/1` is the one setup call, once per workbook: on Google it is a token and a
metadata request, and it authenticates only when there is no good token already. It takes a
`%Sheetshow.Workbook{}`, never a `%Sheetshow.Client{}`.

**A token lasts an hour, and Sheetshow does not renew it for you.** `Sheetshow.Client.ready?/2`
says whether the workbook's token is still good; `Sheetshow.authenticate/1` gets another. A
request made with a dead token is `{:error, %Sheetshow.Error{reason: :http}}` with status 401.

**Sheetshow never looks for a credential.** No well-known path, no environment variable, no
cache. Read the file, hold the value. `Sheetshow.ServiceAccount.from_file!/1` and
`Sheetshow.UserAccount.from_file!/1` are the two readers; `Sheetshow.OAuth` is the consent
flow, minus the browser and the loopback listener, which are the application's.

## Two Reads

    {:ok, cells} = Sheetshow.read_cells("Costs!A1:C10", workbook)   # everything about each cell
    {:ok, rows} = Sheetshow.read_rows("Costs!A1:C10", workbook)     # values, at a twelfth the bytes
    {:ok, [rows_a, rows_b]} = Sheetshow.read_rows(["Costs!A1:C10", "Costs!E1:E10"], workbook)

**A range must name a sheet.** `"A1:C10"` alone is `:invalid_range`. A `%Sheetshow.Range{}` or
an A1 string works everywhere a range is taken; `Sheetshow.Range.from_a1/1` parses one.

**`read_cells/2` gives what was written; `read_rows/2` gives what it works out to.** A formula
comes back as `{:formula, "=SUM(B2:B4)"}` from the first and as its result from the second; a
formula error comes back as text (`"#DIV/0!"`) from the second. A list of ranges to
`read_rows/2` is one request.

## Values

- **A `:decimal` column is a string on both sides.** `Decimal.to_string/1` in, `Decimal.new/1`
  out; no float ever touches it. Sheetshow does not depend on `Decimal`.
- **A `Date` comes back a `Date`; a `DateTime` comes back a `NaiveDateTime`.** The zone is
  dropped on the way in, so store UTC or store the zone in another column.
- **A formula is `{:formula, "=..."}`.** A plain string starting with `=` is written as text.
- **A style is a map**, merged by `Sheetshow.put_style/2`; `Sheetshow.Style.keys/0` lists the
  keys. Colours are `"#RRGGBB"`.
- **Empty cells are left out of a read**, so `length(cells)` counts written cells, not the
  rectangle; `Sheetshow.to_rows/1` puts the gaps back as `nil`.

## The Database on a Tab

`Sheetshow.Log` and `Sheetshow.Table` share `Sheetshow.Schema`, a keyword list of column names
to types (`Sheetshow.Schema.types/0` lists them). Writes are strict, so a wrong type or an
unknown column is refused before any request; reads are lenient, so a cell that will not
cast reads as `nil` with an error on the row, and `strict: true` refuses the read instead.

**More than one writer, use the Log. One writer, either.** Google has no conditional write, so
two processes updating rows in place are last-write-wins. A `Log` append resolves server-side,
so appenders cannot land on each other, and a failed append is safe to send again: the
duplicate ids fold away.

    log = Sheetshow.Log.new("expenses", item: :string, cost: :decimal)
    event = Sheetshow.Log.Event.new(%{item: "Rent", cost: "1000.00"})
    {:ok, workbook} = Sheetshow.run(Sheetshow.Log.create(log) ++ Sheetshow.Log.plan!([event], log), workbook)
    {:ok, events} = Sheetshow.Log.read(log, workbook)
    state = Sheetshow.Log.fold(events)          # latest event per id, tombstones gone

An update is `Sheetshow.Log.Event.put/2` appended again; a delete is `Event.delete/1`.
`Sheetshow.Log.read/3` with `after: last_event` reads only what came since, one request;
`{:error, %{reason: :moved}}` means the rows above the cursor changed, so read whole.

**The `Table` cycle is read → change → refresh → plan → run.**

    table = Sheetshow.Table.new("expenses", item: :string, cost: :decimal)
    {:ok, snapshot} = Sheetshow.Table.read(table, workbook)
    changes = [Sheetshow.Table.update(id, %{cost: "1200.00"}), Sheetshow.Table.delete(other_id)]
    {:ok, snapshot} = Sheetshow.Table.refresh(snapshot, workbook)
    {:ok, workbook} = changes |> Sheetshow.Table.plan!(snapshot) |> Sheetshow.run(workbook)

Changes name rows by id, never by position; `refresh/2` is one small read that finds every
row where it is now, so a row somebody inserted by hand does not make us overwrite the wrong
one. `delete/2` is soft by default (`hard: true` removes the row), `Sheetshow.Table.live/1`
hides the tombstones, and `Sheetshow.Table.compact/1` is the plan that removes them all. A
plan of nothing but `insert/2` is safe against a snapshot of any age, including
`Sheetshow.Table.empty/1`.

## Backends Say What They Cannot Do

`Sheetshow.Backend.capabilities/1` is a map of promises: `:atomic_batch`,
`:conditional_write`, `:dimensions`, `:evaluates_formulas`, `:server_side_append`, `:styles`.
`Sheetshow.Backend.supports?/2` asks for one. Rely on a capability and the backend lacks it,
and the answer is `{:error, %Sheetshow.Error{reason: :unsupported}}` rather than a wrong result.

- **Google**: everything but `:conditional_write`.
- **An `.xlsx` file**: nothing is worked out, so a formula reads back as itself and
  `Sheetshow.Log.view/2` cannot keep a view current; there is no `:server_side_append`, since
  the whole file is written; a WebDAV store gives `:conditional_write`, a local file does not.
- **Memory**: the test double. Same code, no network; it works out no formulas either.

## The Quota

Google allows **60 reads and 60 writes a minute per user**, one unit per request however much
it carries. `connect/1` is two requests; `run/2`, `read_cells/2`, `read_rows/2` (with any
number of ranges), `Table.read/3`, `Table.refresh/2` and `Log.read/3` are one each. Batch: a
loop that writes a row at a time is unusable, a plan of five hundred rows is one request. Over
the limit is `{:error, %Sheetshow.Error{reason: :rate_limited}}` with `details.retry_after` in
seconds when Google named one. Retrying and backing off are the application's.

## Testing Without Google

`Sheetshow.Workbook.memory/1` is a full backend, so application code runs against it unchanged,
and a plan is a list of structs, so the cheapest test asserts on the plan and runs nothing:

    plan = Sheetshow.plan!(cells, existing_sheets: [])
    assert [%Sheetshow.Op.AddSheet{title: "Costs"}, %Sheetshow.Op.PutCells{} | _] = plan

## Things Sheetshow Deliberately Does Not Do

- **No processes, no configuration, no macros.** Nothing to supervise, nothing to `use`, and
  nothing read from `config/`. A schema is a keyword list; a query is `Enum`.
- **No retries, backoff, token cache or scheduling.** Each is the application's, which is the
  only thing that knows what it should be.
- **No Drive.** A workbook is an existing spreadsheet's id; Sheetshow creates tabs, not
  spreadsheets, and needs only the `spreadsheets` scope.
- **No conditional write on Google**, because the API has none; the library makes re-reading
  cheap instead of pretending the gap is closed. `guides/guarantees.md` is the whole argument.
- **No dependencies.** Elixir 1.18 or later for `JSON`; `:public_key`, `:inets`, `:ssl` and
  `:xmerl` from OTP.
