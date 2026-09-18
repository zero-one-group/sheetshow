# What Sheetshow Can Promise

Every write raises two questions: does it land whole, and does it land on the
spreadsheet I read? Google answers the first well and the second not at all, and
most of the database layer's shape follows from that. This page is the argument
made once; the module docs point here rather than repeating it.

## One request, applied whole

A plan compiles to a single `spreadsheets.batchUpdate`, and Google applies the
batch whole or not at all: five hundred cells across four tabs land together or
none of them do. A file backend writes the file whole or not at all, and the
in-memory backend hands back the memory it was given when an op fails. That is
`:atomic_batch`, and every backend Sheetshow ships promises it.

What can go wrong is caught before the request. An op for a sheet the workbook
has not got, a value the schema refuses, an id the snapshot cannot place: each
is an `{:error, %Sheetshow.Error{}}` from `plan/2`, with nothing sent.

## The gap between a read and a write

**The Sheets API has no conditional write.** `batchUpdate` takes `requests`,
`includeSpreadsheetInResponse`, `responseRanges`, `responseIncludeGridData`,
`commentsViewMode` and nothing else: no ETag, no `If-Match`, no revision
precondition. A write to a cell by its position is last-write-wins, and nothing
between your read and your write is guarded.

**The exception is `appendCells`.** An append resolves "below the last row with
data" on Google's side, at the moment it is applied, so two processes appending
to one tab cannot land on each other. That is `:server_side_append`, and it is
the one concurrency promise Google makes.

The two database models are the two sides of that line.

`Sheetshow.Log` rides on the append. Every row is an event with a
client-generated id; an update is the same id appended again, a delete is the
same id with a flag, and the state is the fold, where the latest event per id
wins. Nothing
is written by position, so several writers need no compare-and-swap between
them, and a batch that landed but answered with a transport error can simply be
sent again: the duplicate ids fold away. The one caveat is to retry a failed
batch *before* writing anything newer, or the stale retry lands as the newest
row and wins the fold.

`Sheetshow.Table` writes by position, since row 7 *is* the record, so it is the
model Google gives no help with. What the library does about it is make the
snapshot cheap to check rather than pretend the gap is closed. A change names
its row by id, never by position, so a plan is pure and can be made again
against fresh positions for free; `Sheetshow.Table.refresh/2` is one small
read of the header and the id column that puts every row where it is now; an
update writes only the columns it names, so a column somebody else is editing
survives; and it writes the row's id back too, so a write that landed on the
wrong row shows up as a repeated id at the next read instead of a quietly
overwritten record. Inserts are appends, so a plan of nothing but inserts is
safe against a snapshot of any age. Updates and deletes are not, and the gap
between the refresh and the write is still a gap, a short one.

The rule that falls out: **more than one writer, use the Log. One writer,
either.** Most internal tools have one writer, and it is a `cron` job.

## Files

A file is rewritten whole, so on a file backend an append is a read and a write
with a gap between them, and the append promise is gone: two writers can lose
each other's rows outright. What a file backend has instead is a **store**, and
a store may be able to refuse a write.

`Sheetshow.Store.read/1` hands back the bytes and a version, whatever the store
uses to tell one state of the file from another, and `write/3` sends that
version back as a precondition. `Sheetshow.Store.WebDAV` sends the file's
`ETag` as `If-Match`, so a file that changed in between gets `412` and arrives
as `%Sheetshow.Error{reason: :conflict}` with nothing written. That is
`:conditional_write`, and it is the promise Google cannot make: a `run/2` on a
file is a whole read, change and write, and the precondition makes that atomic,
so of two runs racing the loser is refused rather than silently overwriting the
winner. A `Log` plan that lost that race is safe to run again unchanged, because
its ids fold away against themselves.

It does **not** yet tie a `Table` write to the snapshot it was planned against.
`run/2` re-reads the file at execution rather than writing against the version
the snapshot was read at, so a plan made against an old snapshot can still land
on rows that have moved since, without a conflict. Carrying the observed version
through to the write is what would close that, and is not yet done; until then
`refresh/2` narrows the gap on a file exactly as it does on Google, and no
further.

`Sheetshow.Store.Local` cannot promise it. It checks the file's size and
modification time immediately before an atomic rename, which catches most
clobbering but not all, since the modification time has one-second resolution,
so it answers `conditional_write?` with `false`, and a workbook over it says so.

## The quota

Google allows **60 read requests and 60 write requests a minute per user per
project**, 300 per project, in separate buckets, with no daily cap. The number
that matters is that **one request is one unit however much it carries**: a
plan with five hundred ops costs exactly what a plan with one costs, and a
`values:batchGet` of two ranges costs one read. Batching is therefore the only
lever, and an API that made you loop over rows would be the wrong shape, which
is why every function here takes a list.

Going over is a `429`, and it arrives as `%Sheetshow.Error{reason: :rate_limited}`
with `details.retry_after` in seconds when Google names a wait. It has a reason
of its own precisely so a backoff can be written without matching on error text;
whether and when to try again is your application's, because only it knows
whether the write is safe to repeat. An append is.

The requests a thing costs can be counted at the call site. Creating a tab and
writing its header and first rows is one write. A `Log` append is one write and
a read, cursor or not, is one read. A `Table` cycle is three requests (read,
refresh, run), or two without the refresh. A spreadsheet holds ten million cells
and 18,278 columns; there is no row limit as such.

## Asking the backend

Backends are not equals, and the difference is data rather than a surprise:

| capability | Google | memory | xlsx |
| --- | --- | --- | --- |
| `:atomic_batch` | yes | yes | yes |
| `:server_side_append` | yes | yes | no |
| `:conditional_write` | no | no | the store's to say |
| `:evaluates_formulas` | yes | no | no |
| `:styles`, `:dimensions` | yes | yes | yes |

`Sheetshow.Backend.supports?/2` answers one question and
`Sheetshow.Backend.ensure/2` refuses with `%Sheetshow.Error{reason: :unsupported}`
when the answer is no, which is how code that needs a promise says so up front
rather than finding out later.
