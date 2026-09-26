defmodule Sheetshow.Schema do
  @moduledoc """
  What a row means: a keyword list of `{name, type}`, and the casting either
  way across it.

      iex> schema = [item: :string, cost: :decimal, on: :date]
      iex> Sheetshow.Schema.validate(schema)
      :ok

  A schema is a plain keyword list, not a struct, so it composes with `++` and
  reads as data in a config file. The order is the column order.

  | Type       | Written from                          | Read back as                     |
  |------------|---------------------------------------|----------------------------------|
  | `:string`  | `String.t()`                          | `String.t()`                     |
  | `:integer` | `integer()`                           | `integer()`                      |
  | `:float`   | `number()`                            | `float()`                        |
  | `:boolean` | `true` / `false`                      | `true` / `false`                 |
  | `:date`    | `Date.t()`                            | `Date.t()`                       |
  | `:datetime`| `NaiveDateTime.t()` / `DateTime.t()`  | `NaiveDateTime.t()`              |
  | `:time`    | `Time.t()`                            | `Time.t()`                       |
  | `:decimal` | a numeric `String.t()`                | `String.t()`                     |
  | `:json`    | any term `JSON` can encode            | the decoded term                 |

  `:decimal` is text on both sides, so a double never touches it and `1000.00`
  stays `1000.00`. It is a string here because Sheetshow has no dependencies:
  `Decimal.to_string/1` on the way in and `Decimal.new/1` on the way out is the
  whole of it, and your app decides which library that is.

  **Writing is strict.** `encode/2` refuses a value of the wrong type or a key
  the schema does not have: your code wrote it, so your code should hear about
  it. **Reading is lenient.** `cast/2` is given whatever a human left in the
  cell, so it coerces what Sheets itself would have coerced (a number in a
  `:string` column, a whole number in an `:integer` one), and where a value
  will not cast at all it hands back `nil` and an error beside it rather than
  failing the read.
  """

  alias Sheetshow.{Error, Result, Value}

  @types [:string, :integer, :float, :boolean, :date, :datetime, :time, :decimal, :json]

  @type name :: atom()
  @type type ::
          :string | :integer | :float | :boolean | :date | :datetime | :time | :decimal | :json
  @type t :: [{name(), type()}]
  @type fields :: %{optional(name()) => term()}

  @doc """
  Every type a column can have.

      iex> :decimal in Sheetshow.Schema.types()
      true
  """
  @spec types() :: [type()]
  def types, do: @types

  @doc """
  Checks a schema: at least one column, names that are atoms and appear once,
  types from `types/0`.

      iex> {:error, %Sheetshow.Error{reason: :invalid_schema}} =
      ...>   Sheetshow.Schema.validate(item: :text)
  """
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(schema) do
    cond do
      not (is_list(schema) and schema != [] and Keyword.keyword?(schema)) ->
        {:error,
         invalid("a schema is a non-empty keyword list of {name, type}, got #{inspect(schema)}")}

      (unknown = Enum.reject(Keyword.values(schema), &(&1 in @types))) != [] ->
        {:error,
         invalid("unknown column type #{inspect(hd(unknown))}; the types are #{inspect(@types)}")}

      (repeated = Keyword.keys(schema) -- Enum.uniq(Keyword.keys(schema))) != [] ->
        {:error, invalid("the column #{inspect(hd(repeated))} is in the schema twice")}

      (blank = Enum.find(Keyword.keys(schema), &(String.trim(to_string(&1)) == ""))) != nil ->
        {:error,
         invalid("the column #{inspect(blank)} has no name once surrounding spaces are removed")}

      (colliding = colliding_names(Keyword.keys(schema))) != [] ->
        {:error,
         invalid(
           "the columns #{inspect(colliding)} are the same column once a header is matched, " <>
             "which ignores case and surrounding spaces, so one would silently overwrite the " <>
             "other: give them names that differ by more than that"
         )}

      true ->
        :ok
    end
  end

  # Columns are found on a tab by name, case- and space-insensitively, so two
  # names that differ only by case or spacing are one column. Left in, the last
  # one would silently win; caught here, they never become a plan.
  defp colliding_names(keys) do
    keys
    |> Enum.group_by(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.filter(fn {_canonical, group} -> length(group) > 1 end)
    |> Enum.flat_map(fn {_canonical, group} -> group end)
  end

  @doc """
  The column names, in order, as they read in a header row.

      iex> Sheetshow.Schema.columns(item: :string, cost: :decimal)
      ["item", "cost"]
  """
  @spec columns(t()) :: [String.t()]
  def columns(schema), do: Enum.map(schema, fn {name, _type} -> to_string(name) end)

  @doc """
  A record as the cell values of one row, in schema order. A column the record
  says nothing about is `nil`, which is an empty cell.

  Strict: a value of the wrong type, or a key the schema has no column for, is
  an error.

      iex> Sheetshow.Schema.encode(%{item: "Rent", cost: "1000.00"}, item: :string, cost: :decimal)
      {:ok, ["Rent", "1000.00"]}

      iex> {:error, %Sheetshow.Error{reason: :invalid_record}} =
      ...>   Sheetshow.Schema.encode(%{cost: 1000.0}, cost: :decimal)
  """
  @spec encode(fields(), t()) :: {:ok, [Value.t()]} | {:error, Error.t()}
  def encode(record, schema) when is_map(record) and is_list(schema) do
    case Map.keys(record) -- Keyword.keys(schema) do
      [] -> encode_columns(record, schema)
      [name | _] -> {:error, unknown_column(name, schema)}
    end
  end

  defp encode_columns(record, schema) do
    Result.map(schema, fn {name, type} ->
      value = Map.get(record, name)

      case encode_one(value, type) do
        {:ok, encoded} -> {:ok, encoded}
        :error -> {:error, wrong_type(name, type, value)}
      end
    end)
  end

  # Text has to be UTF-8 to be text at all: a Latin-1 byte written into a file
  # makes the whole workbook unreadable, and Google refuses the request.
  defp encode_one(nil, _type), do: {:ok, nil}
  defp encode_one(value, :string) when is_binary(value), do: utf8(value)
  defp encode_one(value, :integer) when is_integer(value), do: {:ok, value}
  defp encode_one(value, :float) when is_number(value), do: to_float(value)
  defp encode_one(value, :boolean) when is_boolean(value), do: {:ok, value}
  defp encode_one(%Date{} = value, :date), do: {:ok, value}
  defp encode_one(%NaiveDateTime{} = value, :datetime), do: {:ok, value}
  defp encode_one(%DateTime{} = value, :datetime), do: {:ok, value}
  defp encode_one(%Time{} = value, :time), do: {:ok, value}

  defp encode_one(value, :decimal) when is_binary(value) do
    if numeric?(value), do: {:ok, value}, else: :error
  end

  defp encode_one(value, :json) do
    with {:ok, text} <- {:ok, JSON.encode!(value)}, do: utf8(text)
  rescue
    _ -> :error
  end

  defp encode_one(_value, _type), do: :error

  defp utf8(text), do: if(String.valid?(text), do: {:ok, text}, else: :error)

  # An integer too large for a double has no float to become, which is a value
  # of the wrong type rather than a crash.
  defp to_float(value) do
    {:ok, value * 1.0}
  rescue
    ArithmeticError -> :error
  end

  @doc """
  The values of one row, in schema order, as a record, with an error beside
  each cell that would not cast.

  Nothing here fails: a cell Sheets or a person left in a state the column did
  not expect comes back as `nil` in the record and an entry in the errors, so
  one bad cell costs you that field rather than the row or the read.

      iex> Sheetshow.Schema.cast(["Rent", "1000.00"], item: :string, cost: :decimal)
      {%{item: "Rent", cost: "1000.00"}, %{}}

      iex> {record, errors} = Sheetshow.Schema.cast(["abc"], cost: :integer)
      iex> {record.cost, errors.cost.reason}
      {nil, :cast}
  """
  @spec cast([term()], t()) :: {fields(), %{optional(name()) => Error.t()}}
  def cast(values, schema) when is_list(values) and is_list(schema) do
    schema
    |> Enum.zip(pad(values, length(schema)))
    |> Enum.reduce({%{}, %{}}, fn {{name, type}, raw}, {record, errors} ->
      case cast_one(raw, type) do
        {:ok, value} -> {Map.put(record, name, value), errors}
        :error -> {Map.put(record, name, nil), Map.put(errors, name, cast_error(name, type, raw))}
      end
    end)
  end

  defp pad(values, size) do
    values ++ List.duplicate(nil, max(size - length(values), 0))
  end

  @doc """
  Reads a cell the way a `:boolean` column does, which is also how a log reads
  its `deleted` flag. Blank is `false`; `TRUE`, `true` and `1` are `true`.

      iex> Sheetshow.Schema.cast_boolean("TRUE")
      {:ok, true}
      iex> Sheetshow.Schema.cast_boolean("")
      {:ok, false}
      iex> Sheetshow.Schema.cast_boolean("perhaps")
      :error
  """
  @spec cast_boolean(term()) :: {:ok, boolean()} | :error
  def cast_boolean(value) do
    case blank(value) do
      nil -> {:ok, false}
      true -> {:ok, true}
      false -> {:ok, false}
      # A backend that keeps floats hands 1 back as 1.0.
      number when number == 1 -> {:ok, true}
      number when number == 0 -> {:ok, false}
      string when is_binary(string) -> from_word(String.downcase(string))
      _other -> :error
    end
  end

  defp from_word(word) when word in ~w(true yes y 1), do: {:ok, true}
  defp from_word(word) when word in ~w(false no n 0), do: {:ok, false}
  defp from_word(_other), do: :error

  defp cast_one(raw, type) do
    case blank(raw) do
      nil -> {:ok, nil}
      value -> cast_value(value, type)
    end
  end

  defp cast_value(value, :string) when is_binary(value), do: {:ok, value}
  defp cast_value(value, :string) when is_number(value), do: {:ok, printed(value)}
  defp cast_value(value, :string) when is_boolean(value), do: {:ok, upcase(value)}

  defp cast_value(value, :integer) when is_integer(value), do: {:ok, value}

  defp cast_value(value, :integer) when is_float(value) do
    if trunc(value) == value, do: {:ok, trunc(value)}, else: :error
  end

  defp cast_value(value, :integer) when is_binary(value), do: parse(value, &Integer.parse/1)

  defp cast_value(value, :float) when is_number(value), do: to_float(value)
  defp cast_value(value, :float) when is_binary(value), do: parse(value, &Float.parse/1)

  defp cast_value(value, :boolean), do: cast_boolean(value)

  defp cast_value(value, kind) when kind in [:date, :datetime, :time] and is_number(value) do
    {:ok, Value.from_serial(value, kind)}
  rescue
    # A serial outside the years a date can hold is not a moment anyone meant:
    # a nil field and a :cast error, the same as any other value that will not
    # read, rather than raising out of a read (or, as it once did, never
    # returning from one).
    ArgumentError -> :error
  end

  # A backend that keeps values rather than serial numbers (`Sheetshow.Memory`,
  # and `Sheetshow.read_cells/2` on a cell Sheets formats as a date) hands the
  # temporal kinds back already made. A zone is dropped on the way out, as it is
  # on the way in.
  defp cast_value(%Date{} = value, :date), do: {:ok, value}
  defp cast_value(%NaiveDateTime{} = value, :datetime), do: {:ok, value}
  defp cast_value(%DateTime{} = value, :datetime), do: {:ok, DateTime.to_naive(value)}
  defp cast_value(%Time{} = value, :time), do: {:ok, value}

  # A moment of another kind than the column's: a `.xlsx` file reads a number as
  # whatever its format shows, so a timestamp somebody formatted as a date is a
  # `NaiveDateTime` in a `:date` column. Google hands the same cell back as its
  # serial number, and the column makes what it makes of that; so does this, by
  # way of the serial, so the backends agree on every such cell, the number and
  # text columns included.
  defp cast_value(%struct{} = value, type)
       when struct in [Date, NaiveDateTime, DateTime, Time],
       do: cast_value(Value.to_serial(value), type)

  defp cast_value(value, :date) when is_binary(value), do: parsed(Date.from_iso8601(value))

  defp cast_value(value, :datetime) when is_binary(value) do
    parsed(NaiveDateTime.from_iso8601(value))
  end

  defp cast_value(value, :time) when is_binary(value), do: parsed(Time.from_iso8601(value))

  # Someone typed a bare number where a decimal lives: keep the digits Sheets
  # kept, and accept that 1000.00 came back as 1000.0. That is why the column
  # is written as text in the first place.
  defp cast_value(value, :decimal) when is_number(value), do: {:ok, printed(value)}

  defp cast_value(value, :decimal) when is_binary(value) do
    trimmed = String.trim(value)
    if numeric?(trimmed), do: {:ok, trimmed}, else: :error
  end

  defp cast_value(value, :json) when is_binary(value), do: parsed(JSON.decode(value))

  # A JSON scalar somebody typed by hand arrives as the number or boolean Sheets
  # made of it, which is what decoding the text would have given anyway.
  defp cast_value(value, :json) when is_number(value) or is_boolean(value), do: {:ok, value}

  defp cast_value(_value, _type), do: :error

  # An empty cell and a cell holding "" are the same thing to a reader.
  defp blank(nil), do: nil
  defp blank(""), do: nil

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _kept -> value
    end
  end

  defp blank(value), do: value

  defp upcase(true), do: "TRUE"
  defp upcase(false), do: "FALSE"

  # A number as the sheet showed it: the fewest digits that read back as the
  # same double, which is what a person typed (19.99, not the 19.989999999999998
  # a fixed count of decimals prints), and in plain decimal form rather than the
  # exponent `Kernel.to_string/1` gives 1000.0 ("1.0e3"). A magnitude too far
  # from 1 to print plainly in a reasonable width (below 1.0e-7 or from 1.0e21, the
  # bounds JavaScript prints numbers by) keeps its exponent, since a wrong number
  # and a thousand zeros are both worse than one.
  defp printed(value) when is_integer(value), do: Integer.to_string(value)

  defp printed(value) when is_float(value) do
    short = :erlang.float_to_binary(value, [:short])

    case Regex.run(~r/\A(-?)(\d+)\.(\d+)e(-?\d+)\z/, short) do
      [_, sign, whole, fraction, exponent] ->
        plain(sign, whole, fraction, String.to_integer(exponent)) || short

      nil ->
        short
    end
  end

  # `d.ddd` times ten to `exponent`, as plain digits with the point moved.
  defp plain(sign, whole, fraction, exponent) when exponent >= -7 and exponent < 21 do
    digits = String.trim_trailing(whole <> fraction, "0")
    digits = if digits == "", do: "0", else: digits
    point = String.length(whole) + exponent

    {integer, decimals} =
      cond do
        point <= 0 ->
          {"0", String.duplicate("0", -point) <> digits}

        point >= String.length(digits) ->
          {digits <> String.duplicate("0", point - String.length(digits)), "0"}

        true ->
          String.split_at(digits, point)
      end

    sign <> integer <> "." <> decimals
  end

  defp plain(_sign, _whole, _fraction, _exponent), do: nil

  defp parse(string, parser) do
    case parser.(String.trim(string)) do
      {value, ""} -> {:ok, value}
      _other -> :error
    end
  end

  defp parsed({:ok, value}), do: {:ok, value}
  defp parsed(_other), do: :error

  # Decimal syntax, read as syntax: `Float.parse/1` refuses a number a double
  # cannot hold (`1E+400`), which is exactly what a decimal column is for.
  defp numeric?(string) do
    Regex.match?(~r/\A[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\z/, String.trim(string))
  end

  defp invalid(message), do: Error.new(:invalid_schema, message)

  defp unknown_column(name, schema) do
    Error.new(
      :unknown_column,
      "the record has #{inspect(name)}, which the schema has no column for",
      column: name,
      columns: Keyword.keys(schema)
    )
  end

  defp wrong_type(name, type, value) do
    Error.new(
      :invalid_record,
      "#{inspect(name)} is #{inspect(type)}, so #{inspect(value)} cannot be written there",
      column: name,
      type: type,
      value: value
    )
  end

  defp cast_error(name, type, {:formula, _} = value) do
    Error.new(
      :cast,
      "#{inspect(value)} does not read as #{inspect(type)}: it is a formula nothing has worked " <>
        "out yet, which is what a backend that evaluates no formulas holds until a spreadsheet " <>
        "opens the file and saves it",
      column: name,
      type: type,
      value: value
    )
  end

  defp cast_error(name, type, value) do
    Error.new(
      :cast,
      "#{inspect(value)} does not read as #{inspect(type)}",
      column: name,
      type: type,
      value: value
    )
  end
end
