defmodule Sheetshow.Log.Event do
  @moduledoc """
  One row of a log: an id, what it says, and whether it says the row is gone.

      iex> event = Sheetshow.Log.Event.new(%{item: "Rent", cost: "1000.00"})
      iex> {byte_size(event.id), event.deleted, event.record.item}
      {26, false, "Rent"}

  An event is a value you hold on to. Writing one is `Sheetshow.Log.plan/2`;
  changing it later is the same id written again, and deleting it is the same
  id written again with `deleted` set. Nothing is edited in place, on the sheet
  or here, which is what makes a failed write safe to retry: the same id
  appended twice folds to one row.

  `row` and `errors` are filled in by a read and are empty on an event you made
  yourself. `errors` is a map from column name to `Sheetshow.Error`: a cell a
  person typed that would not cast leaves the field `nil` and says so here,
  rather than taking the row or the read down with it.
  """

  alias Sheetshow.{Schema, ULID}

  defstruct [:id, :row, record: %{}, deleted: false, errors: %{}]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          row: non_neg_integer() | nil,
          record: Schema.fields(),
          deleted: boolean(),
          errors: %{optional(Schema.name()) => Sheetshow.Error.t()}
        }

  @doc """
  An event holding a record, with an id of its own unless you pass one.

  Options: `:id`, any non-empty string, since a ULID is only the default, so an
  invoice number or a key your app already has is just as good; and `:deleted`,
  to make a tombstone in one step.

      iex> Sheetshow.Log.Event.new(%{item: "Rent"}, id: "invoice-104").id
      "invoice-104"
  """
  @spec new(Schema.fields(), keyword()) :: t()
  def new(record, opts \\ []) when is_map(record) and is_list(opts) do
    %__MODULE__{
      id: id(Keyword.get(opts, :id)),
      record: record,
      deleted: Keyword.get(opts, :deleted, false)
    }
  end

  defp id(nil), do: ULID.generate()
  defp id(given) when is_binary(given) and given != "", do: given

  defp id(other) do
    raise ArgumentError, "an event's id is a non-empty string, got #{inspect(other)}"
  end

  @doc """
  Merges changes into the record, keeping the id: the update you append next.

      iex> Sheetshow.Log.Event.new(%{item: "Rent", cost: "1000.00"})
      ...> |> Sheetshow.Log.Event.put(%{cost: "1100.00"})
      ...> |> Map.fetch!(:record)
      %{item: "Rent", cost: "1100.00"}
  """
  @spec put(t(), Schema.fields()) :: t()
  def put(%__MODULE__{record: record} = event, changes) when is_map(changes) do
    %{event | record: Map.merge(record, changes)}
  end

  @doc """
  The tombstone that takes a row out of the fold.

  Given an event, the record travels with it, so someone reading the tab sees
  what went; given a bare id, the tombstone is a row with nothing but that id
  and the flag.

      iex> Sheetshow.Log.Event.delete("invoice-104")
      %Sheetshow.Log.Event{id: "invoice-104", row: nil, record: %{}, deleted: true, errors: %{}}
  """
  @spec delete(t() | String.t()) :: t()
  def delete(%__MODULE__{} = event), do: %{event | deleted: true}
  def delete(id) when is_binary(id), do: %__MODULE__{id: id(id), deleted: true}

  @doc """
  Whether a read left anything flagged on this event.

      iex> Sheetshow.Log.Event.new(%{item: "Rent"}) |> Sheetshow.Log.Event.errors?()
      false
  """
  @spec errors?(t()) :: boolean()
  def errors?(%__MODULE__{errors: errors}), do: map_size(errors) > 0
end
