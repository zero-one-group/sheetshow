# Changelog

Pre-1.0: a minor version may rename or remove. When it does, the migration is one
line here.

## 0.1.1 (2026-09-17)

Fixes from a QA pass over 0.1.0, all in the `.xlsx` codec unless said otherwise:

- A column of formulas Excel filled down (one `<f t="shared">` and pointers under it)
  read as empty formulas and was written back as `<f></f>`, taking the formulas
  out of the file. Each cell now reads as the shared formula moved to it.
- Conditional formatting's fonts and fills (under `<dxfs>`) were counted with the
  lists a cell indexes into, so a new style pointed past the end of `<fonts>`.
- Deleting a sheet whose name a writer had escaped its own way (`Q1&apos;s`, as
  LibreOffice does) left the `<sheet>` element behind, pointing at a part that
  was gone.
- Adding a string rewrote the shared string table from the text alone, flattening
  rich text in every other cell of the workbook. The table is spliced now.
- A worksheet whose elements carry a namespace prefix (`<x:sheetData>`) is read
  but refused a write, rather than written back with two `sheetData` elements.
- `Sheetshow.Table.refresh/2`: an id the snapshot had read twice, one of whose rows
  had since gone, came back as two rows on one sheet row with the flag cleared.
  Both stay flagged until a fresh read.
- `Sheetshow.records/3` raised on `header: false`.
- A colour such as `"#FF8800\n"` passed `Sheetshow.Style.validate/1` and failed in
  the Google encoder; a sheet name or reference with a trailing newline parsed.
- `Sheetshow.Schema.cast/2`: a `:json` column accepts a number or boolean a
  person typed, and a `:boolean` column accepts `1.0` and `0.0`.
- Every function that takes options now refuses an option it does not know, as
  `Sheetshow.plan/2` already did: the layout builders, `Sheetshow.Client.new/2`,
  `Sheetshow.Workbook.xlsx/2`, `Sheetshow.Token`, `Sheetshow.Log.Event.new/2`,
  `Sheetshow.Table.insert/2` and `delete/2`, `Sheetshow.OAuth`,
  `Sheetshow.ServiceAccount.assertion/2`, `Sheetshow.UserAccount.new/3` and
  `Sheetshow.Store.webdav/2`.

## 0.1.0 (2026-09-16)

The first release. What is in it:

- **Cells and layout.** `Sheetshow.Cell`, `Sheetshow.Coord`, `Sheetshow.Range` and
  `Sheetshow.A1`, giving 0-indexed coordinates, inclusive ranges, quoted sheet
  names and open-ended ranges, with `Sheetshow.Value` (numbers, text, booleans,
  formulas, dates and times as serial numbers) and `Sheetshow.Style` (a plain
  map). Layout on `Sheetshow`: `row`, `col`, `rows`, `records`,
  `to_rows`, `stack`, `beside`, `pad_below`, `pad_right`, `shift`, `put_sheet`,
  `put_style`, `max_row` and `max_col`.
- **Plans.** `Sheetshow.plan/2` turns cells into backend-neutral ops (`AddSheet`,
  `DeleteSheet`, `PutCells`, `AppendRows`, `DeleteRows`, `SetDimensions`), one
  `PutCells` per run so a write never clears a neighbour, and `Sheetshow.run/2`
  carries a plan out in one request. `Sheetshow.read_cells/2` reads cells with
  everything about them; `read_rows/2` reads computed values, one or several
  ranges in one request.
- **Backends.** `Sheetshow.Workbook` over Google Sheets (`Sheetshow.Google`, OTP's
  `:httpc`, TLS verified explicitly, the quota as `:rate_limited`), over an
  in-memory spreadsheet that doubles as the test double, and over `.xlsx` files,
  read one tab at a time and written back with every untouched part copied across
  compressed, on a local file or a WebDAV server, where `If-Match` makes a write
  conditional. `Sheetshow.Backend.capabilities/1` says what each promises.
- **A database on a tab.** `Sheetshow.Schema` as a keyword list; `Sheetshow.Log`,
  an append-only tab whose state is the fold over its rows, with a cursor read and
  a view tab; `Sheetshow.Table`, mutable rows found again by id, with soft delete,
  `refresh/2` and a planner that orders hard deletes bottom-up; `Sheetshow.ULID`
  for client-generated ids.
- **Credentials.** `Sheetshow.ServiceAccount` and `Sheetshow.UserAccount`, both
  reduced to one `Sheetshow.Token`; `Sheetshow.OAuth` builds the consent URL and
  reads the answer, with PKCE, `access_type=offline` and `prompt=consent` as the
  defaults.
- **Guides that run.** Two quick starts, against Google and against an `.xlsx`
  file; setting up Google; a cookbook; the case for Sheets instead of Postgres;
  and what Sheetshow can promise. Every `elixir` block in them is executed by the
  test suite. A cheatsheet generated from the compiled modules, and
  `usage-rules.md` for an agent's context.
- No dependencies, no processes, no macros.
