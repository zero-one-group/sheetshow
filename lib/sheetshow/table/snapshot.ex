defmodule Sheetshow.Table.Snapshot do
  @moduledoc """
  A table as it was when you read it: the rows, and where each of them sat.

  A snapshot is what a write is planned against, so it is the value to hold on
  to between reading and writing, and the value that goes stale.
  `Sheetshow.Table.refresh/2` re-reads the id column alone and gives back the
  same snapshot with the positions it finds.

  `header` is the header row as it actually reads on the tab, in the tab's own
  order, not the schema's. A table is written by row and column index, so it
  can find its columns by name and leave alone whatever a person keeps to the
  right of them.

  `rows` is every row on the tab, tombstones included. `Sheetshow.Table.live/1`
  is the live ones, which is what most code wants.
  """

  alias Sheetshow.Table
  alias Sheetshow.Table.Row

  @enforce_keys [:table, :header, :rows]
  defstruct [:table, :header, :rows]

  @type t :: %__MODULE__{table: Table.t(), header: [term()], rows: [Row.t()]}
end
