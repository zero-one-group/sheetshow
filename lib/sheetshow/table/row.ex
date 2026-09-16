defmodule Sheetshow.Table.Row do
  @moduledoc """
  One row of a table: an id, what it says, and where on the tab it sits.

  `row` is the sheet row this was read from, and unlike a log's, it is load
  bearing: it is how a later write finds this record again. It is only ever
  true of the snapshot it came in: a row somebody inserts above moves it, and
  `Sheetshow.Table.refresh/2` is what finds out.

  `errors` maps a column name to a `Sheetshow.Error`. A cell that would not
  cast leaves its field `nil` and says so here rather than taking the read
  down; so does a row with no id, and a row whose id another row already used.

  This is deliberately not `Sheetshow.Log.Event`, though the fields line up. An
  event is a line of history you never edit; a row is a place on a tab you
  write over. The two models share the reading machinery underneath, not the
  vocabulary on top.
  """

  alias Sheetshow.{Error, Schema}

  defstruct [:id, :row, record: %{}, deleted: false, errors: %{}]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          row: non_neg_integer() | nil,
          record: Schema.fields(),
          deleted: boolean(),
          errors: %{optional(Schema.name()) => Error.t()}
        }

  @doc """
  Whether anything on this row would not read.

      iex> Sheetshow.Table.Row.errors?(%Sheetshow.Table.Row{id: "a"})
      false
  """
  @spec errors?(t()) :: boolean()
  def errors?(%__MODULE__{errors: errors}), do: errors != %{}
end
