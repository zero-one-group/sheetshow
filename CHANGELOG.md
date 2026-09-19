# Changelog

Pre-1.0: a minor version may rename or remove. When it does, the migration is one
line here.

## 0.1.4 (2026-09-19)

A third external review pass over 0.1.3, correctness and safety again, most of it
in the `.xlsx` codec.

- **Adding a sheet could redirect an existing one to an empty part.** A workbook
  that quoted its relationship attributes with `'` read fine, but the next
  relationship id was allocated by a `Id="rId..."` regex that saw none of them, so
  a new sheet claimed `rId1` on top of one already in use and the old tab resolved
  to the new, empty worksheet. The id, and the next sheet id beside it, are read
  through the parser now, so the same file the reader accepts is the file they
  allocate against.
- **calcChain cleanup missed a valid spelling.** Removing the part left its
  relationship and content-type override behind when the declaration used
  whitespace around its `=` or a separate closing tag rather than a self-closing
  one. Removal is one spelling-agnostic pass now, tolerant of a namespace prefix,
  either quote style, that whitespace and either closing form, and the same pass
  removes a deleted sheet's `<sheet>` element.
- **A namespace-prefixed styles part was only half-detected.** The guard checked
  the root `<styleSheet>` alone, so a file whose root was unprefixed but whose
  `<fonts>`, `<fills>` or `<cellXfs>` lists were prefixed slipped through and had a
  second, unprefixed list appended with an index no cell could resolve. The lists
  are checked too now, and such a part is read-only, refused with `:unsupported`.
- **A shared or inline string that looked like an escape read back wrong.** The
  SpreadsheetML `_xHHHH_` escaping (a control character, or a literal underscore
  written `_x005F_`) is not XML escaping and the parser does not undo it; a literal
  `_x0041_` came back as the encoded `_x005F_x0041_` and a carriage return as
  `_x000D_`. It is decoded on read, in one pass so `_x005F_x0041_` is the literal
  `_x0041_` and not `A`, and encoded to match on write.
- **A values read over a file ignored a formula's cached result.** `read_rows/2`
  returned the formula rather than the value a spreadsheet cached beside it, so a
  `Table` or `Log` field over `.xlsx` cast the formula and came back nil. It gives
  the computed value now, the way Google's values read does, with a cached error as
  its text; `read_cells/2` still returns the formula, with the result in its
  metadata.
- **A number cast into a text column lost precision or raised.** Fixed 15 decimals
  rounded a value just above `1.0e-15` to fewer digits than it had, and raised
  outright on a magnitude like `1.0e308`. The shortest round-tripping form is
  written whenever the fixed one would not read back the same, so every finite
  float round-trips and the lenient cast stays lenient.
- **A log cursor read truncated columns a whole read kept.** The header and the
  rows from the cursor were both bounded to the schema's width, so a column added
  to the tab by hand pushed a real column out of range and the read failed with
  `:missing_column` where a whole read found it by name. The header is read whole
  now, and a tab wider than its schema costs a second request rather than dropping
  the columns.

## 0.1.3 (2026-09-18)

A second external review pass over 0.1.2, all correctness or safety, all in the
`.xlsx` codec unless said otherwise.

- **A built-in elapsed format (46, `[h]:mm:ss`) still lost whole days.** 0.1.2 fixed
  the custom-format route but the built-in table kept a hardcoded `:time`; both
  routes now read the format code through one classifier, so 36 hours stays the
  number `1.5` rather than a 12-hour `Time`.
- **An ISO time-only cell (`t="d"` holding `12:30:00`, from `iso_dates`) read as nil**
  and was erased on the next write; it now reads as a `Time`.
- **A standalone error cell is preserved on write.** 0.1.2 stopped the crash but
  blanked the cell on an unrelated edit; the `t="e"` cell is now written back as it
  was read.
- **`Sheetshow.Store.Local`** created its temporary file, wrote the bytes, then made
  it private, leaving a window where the new contents were readable at the process
  umask; it is now made private while empty, before the bytes, and removed on every
  failure path.
- **calcChain cleanup** removed the part but left a namespace-prefixed
  (`<r:Relationship>`) or single-quoted relationship or content-type override
  behind; removal now matches every spelling its discovery does.
- **Header names are canonicalized one way.** A schema column with surrounding
  space built a table its own read then rejected as `:missing_column`, and a padded
  reserved name (`:" id "`) slipped past the constructor; validation and indexing
  now share one trim-and-downcase rule, and a blank column name is refused.
- **Adding a style to a namespace-prefixed styles part** wrote an index the file
  could not resolve; such a part is now read-only and the write is refused with
  `:unsupported`, the way a prefixed worksheet already is.
- **Deleting the last sheet** produced a workbook no reader could open; a plan that
  would leave no sheets is refused (`:invalid_xlsx`), checked on the final state so
  delete-then-add in one batch still works.
- **Google whole-sheet reads** sent a bare tab name (`Costs`), which Google can
  resolve to a same-named named range in preference to the sheet; whole-sheet reads
  now quote the name.

## 0.1.2 (2026-09-18)

Fixes from an external review of 0.1.1. Correctness, and a more honest account of
what the concurrency story does and does not cover.

- **`.xlsx` reads that lost data.** An ISO-date cell (`t="d"`, from a workbook
  saved with `iso_dates`) read as nil and, since it read as nothing, was erased on
  the next write; it now reads as a `Date` or `NaiveDateTime`. An elapsed duration
  (`[h]:mm:ss`) read as a `Time`, throwing away whole days (36 hours became 12); it
  keeps its number and its format now. A float smaller than `1.0e-15` (such as
  `1.0e-20`) was written as `0`; the shortest round-tripping form is written
  instead. An error cell (`#DIV/0!`) with no formula crashed any write to its
  sheet; the error now reads into the cell's metadata, the same place a formula's
  error goes, so the write succeeds. (Writing such a cell back verbatim is still to
  come; an untouched error cell rewrites empty for now.)
- **`.xlsx` writes that corrupted the file.** A shared-string table spelled with a
  namespace prefix (`<x:sst>`) silently dropped a newly added string, so the cell
  read back nil; mutations are namespace-aware now. Removing `calcChain.xml` left
  its relationship and content-type override behind, pointing at a part that was
  gone; both go with it.
- **A local write no longer loosens a file's permissions.** Replacing a `0600`
  file produced a `0644` one, because the temporary file took the process umask.
  The destination's mode is now preserved, a new file is created `0600`, and the
  temporary file is created exclusively.
- **`Sheetshow.Table.compact/1`** no longer deletes a live row when a tombstone
  shares its id after a refresh: an ambiguous tombstone is left for a fresh read to
  resolve.
- **Reserved and colliding columns are refused.** `Sheetshow.Table.new/2` and
  `Sheetshow.Log.new/2` reject a schema with an `id` or `deleted` column, or two
  columns that differ only by case or spacing; a tab whose header names a needed
  column twice reads as `%Sheetshow.Error{reason: :duplicate_column}` rather than
  silently taking the last.
- **`Sheetshow.Schema.cast/2`** turns a serial number too large to convert into a
  `:cast` error, rather than raising.
- **WebDAV**: a `PUT` that returns no `ETag` leaves the version `:unknown` instead
  of adopting one from a follow-up `HEAD`, which could be a racing writer's.
- **Google**: a batch that adds a tab and then deletes it in one plan no longer
  leaves the tab in the remembered metadata; adds and deletes are applied in order.
- **What Sheetshow can promise, corrected.** A conditional-write store makes each
  `run/2` on a file atomic against a racing writer, but does not yet tie a `Table`
  write to the snapshot it was planned against, because `run/2` re-reads the file
  at execution. The guide, the `Sheetshow.Table` docs and the README said this gap
  was closed; they now say it is not, and the README's retry note carries the same
  caveat the guide always has.

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
