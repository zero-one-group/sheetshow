defmodule Sheetshow.Table.Change do
  @moduledoc """
  One thing to do to a table: a value, made by `Sheetshow.Table.insert/2`,
  `Sheetshow.Table.update/2`, `Sheetshow.Table.delete/2` or
  `Sheetshow.Table.restore/1`.

  A change names a row by **id**, never by where it sits. That is what makes
  `Sheetshow.Table.refresh/2` worth having: when the rows have shifted under
  you, the changes you are holding are still the right changes, and planning
  them again against fresh positions costs nothing and asks Google nothing.

      iex> alias Sheetshow.Table
      iex> Table.update("a", %{cost: "1100.00"}).action
      :update
      iex> Table.delete("a", hard: true).hard
      true

  `record` is only the columns the change names. An update writes those and
  leaves every other cell on the row alone, which is also what keeps a column
  somebody else was editing out of harm's way.
  """

  alias Sheetshow.Schema

  @enforce_keys [:action]
  defstruct [:action, :id, record: %{}, hard: false]

  @type action :: :insert | :update | :delete | :restore

  @type t :: %__MODULE__{
          action: action(),
          id: String.t() | nil,
          record: Schema.fields(),
          hard: boolean()
        }
end
