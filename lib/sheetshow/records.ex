defmodule Sheetshow.Records do
  @moduledoc false
  # What `Log` and `Table` both have to do to a tab full of rows.
  #
  # Both keep records under a header whose first two columns are `id` and
  # `deleted`, both find their columns by name rather than by position when
  # reading, and both are lenient about what a person may have typed into a
  # cell. That is the fiddly, well-tested half of either model, and it has no
  # opinion about which of them it is working for, so it lives here once, and
  # `Log.decode/3` and `Table.decode/3` put their own struct around the result.
  #
  # What is *not* here is everything the two models disagree about: a log is
  # appended to and folded, a table is written by row index and verified. Those
  # stay in their own modules, which is the whole reason `Log.Event` and
  # `Table.Row` are separate structs over identical fields.

  alias Sheetshow.{Cell, Coord, Error, Result, Schema}

  @id "id"
  @deleted "deleted"

  @doc "The `id` column's name, as it is written on a tab."
  def id_column, do: @id

  @doc "The `deleted` column's name, as it is written on a tab."
  def deleted_column, do: @deleted

  @doc "A tab's columns, left to right: the two reserved ones, then the schema's."
  def columns(schema), do: [@id, @deleted | Schema.columns(schema)]

  @doc "The header row as cells, for the tab a `%Log{}` or `%Table{}` names."
  def header(%{sheet: sheet, schema: schema}, style) do
    schema |> columns() |> Sheetshow.row(sheet: sheet, style: style)
  end

  @doc """
  Rows of cell values to plain record maps, `%{id, row, record, deleted,
  errors}`, with the header they were read against.

  Takes `:header` and `:row`, as documented on `Log.decode/3` and
  `Table.decode/3`; the caller has already validated the options. `:strict` is
  `strict/2`'s business, because a caller may have flags of its own to add
  before the question is asked.
  """
  def decode(rows, %{sheet: sheet, schema: schema}, opts) when is_list(rows) do
    {header, data, first} = split(rows, opts)

    with {:ok, index} <- index(header, sheet, schema) do
      records =
        data
        |> Enum.with_index(first)
        |> Enum.reject(fn {row, _number} -> blank?(row) end)
        |> Enum.map(fn {row, number} -> record(row, number, index, schema) end)

      {:ok, {header, records}}
    end
  end

  defp split(rows, opts) do
    case Keyword.fetch(opts, :header) do
      {:ok, header} -> {header, rows, Keyword.get(opts, :row, 1)}
      :error -> {List.first(rows) || [], Enum.drop(rows, 1), Keyword.get(opts, :row, 0) + 1}
    end
  end

  @doc """
  Where each column the schema needs sits on the tab, by name: `%{"id" => 0,
  ...}`. A read needs it to find its fields; a write needs it to put them back
  in the same places.
  """
  def index(header, sheet, schema) do
    positions =
      for {name, position} <- Enum.with_index(header),
          key = normalise(name),
          key != nil,
          into: %{} do
        {key, position}
      end

    if positions == %{} do
      {:error,
       Error.new(
         :missing_header,
         "#{inspect(sheet)} has no header row: its first row is #{inspect(header)}",
         sheet: sheet,
         header: header
       )}
    else
      Result.reduce(columns(schema), %{}, fn name, acc ->
        case Map.fetch(positions, String.downcase(name)) do
          {:ok, position} -> {:ok, Map.put(acc, name, position)}
          :error -> {:error, missing_column(name, sheet, header)}
        end
      end)
    end
  end

  defp normalise(nil), do: nil

  defp normalise(name) do
    case name |> to_string() |> String.trim() |> String.downcase() do
      "" -> nil
      key -> key
    end
  end

  defp missing_column(name, sheet, header) do
    Error.new(
      :missing_column,
      "#{inspect(sheet)} has no #{inspect(name)} column: its header reads #{inspect(header)}",
      column: name,
      sheet: sheet,
      header: header
    )
  end

  @doc """
  A cell for a row written outside the planner (an append, or a write to a
  known row), with the number format a date needs, which those paths would
  otherwise never pick up.
  """
  def cell(row, col, value) do
    Cell.with_number_format(Cell.new(Coord.new(row, col), value))
  end

  defp blank?(row), do: Enum.all?(row, &(&1 == nil or &1 == ""))

  defp record(row, number, index, schema) do
    {record, errors} =
      schema
      |> Enum.map(fn {name, _type} -> at(row, index[to_string(name)]) end)
      |> Schema.cast(schema)

    {id, errors} = id(at(row, index[@id]), errors)
    {deleted, errors} = deleted(at(row, index[@deleted]), errors)

    %{id: id, row: number, record: record, deleted: deleted, errors: errors}
  end

  defp at(row, position), do: Enum.at(row, position)

  defp id(value, errors) when value in [nil, ""] do
    {nil, Map.put(errors, :id, Error.new(:cast, "the row has no id", column: :id, value: value))}
  end

  defp id(value, errors), do: {to_string(value), errors}

  # A flag nobody can read should not quietly hide a row, so it reads as live
  # and says so.
  defp deleted(value, errors) do
    case Schema.cast_boolean(value) do
      {:ok, deleted} ->
        {deleted, errors}

      :error ->
        error =
          Error.new(:cast, "#{inspect(value)} does not read as a deleted flag",
            column: :deleted,
            value: value
          )

        {false, Map.put(errors, :deleted, error)}
    end
  end

  @doc """
  With `strict: true`, refuses the read when any row carries a flag; otherwise
  hands back what it was given. Works on anything with `row` and `errors`, so
  each model applies it to its own struct once its own flags are on.
  """
  def strict(records, opts) do
    if Keyword.get(opts, :strict, false), do: refuse(records), else: {:ok, records}
  end

  defp refuse(records) do
    case Enum.find(records, &(&1.errors != %{})) do
      nil ->
        {:ok, records}

      record ->
        {column, error} = record.errors |> Enum.sort() |> hd()

        # The flag's own reason, not a blanket one: a cell that would not cast
        # and an id two rows are wearing are different problems to have.
        {:error,
         Error.new(
           error.reason,
           "row #{record.row}, #{inspect(column)}: #{Exception.message(error)}",
           row: record.row,
           column: column,
           value: error.details[:value],
           flagged: Enum.count(records, &(&1.errors != %{}))
         )}
    end
  end
end
