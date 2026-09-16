# Changelog

Pre-1.0: a minor version may rename or remove. When it does, the migration is one
line here.

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
