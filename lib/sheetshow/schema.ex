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

  defp encode_one(nil, _type), do: {:ok, nil}
  defp encode_one(value, :string) when is_binary(value), do: {:ok, value}
  defp encode_one(value, :integer) when is_integer(value), do: {:ok, value}
  defp encode_one(value, :float) when is_number(value), do: {:ok, value * 1.0}
  defp encode_one(value, :boolean) when is_boolean(value), do: {:ok, value}
  defp encode_one(%Date{} = value, :date), do: {:ok, value}
  defp encode_one(%NaiveDateTime{} = value, :datetime), do: {:ok, value}
  defp encode_one(%DateTime{} = value, :datetime), do: {:ok, value}
  defp encode_one(%Time{} = value, :time), do: {:ok, value}

  defp encode_one(value, :decimal) when is_binary(value) do
    if numeric?(value), do: {:ok, value}, else: :error
  end

  defp encode_one(value, :json) do
    {:ok, JSON.encode!(value)}
  rescue
    _ -> :error
  end

  defp encode_one(_value, _type), do: :error

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

  defp cast_value(value, :float) when is_number(value), do: {:ok, value * 1.0}
  defp cast_value(value, :float) when is_binary(value), do: parse(value, &Float.parse/1)

  defp cast_value(value, :boolean), do: cast_boolean(value)

  defp cast_value(value, kind) when kind in [:date, :datetime, :time] and is_number(value) do
    {:ok, Value.from_serial(value, kind)}
  rescue
    # A serial so large the conversion overflows is not a moment anyone meant.
    # Lenient casting turns that into a nil field and a :cast error, the same as
    # any other value that will not read, rather than raising out of a read.
    ArithmeticError -> :error
  end

  # A backend that keeps values rather than serial numbers (`Sheetshow.Memory`,
  # and `Sheetshow.read_cells/2` on a cell Sheets formats as a date) hands the
  # temporal kinds back already made. A zone is dropped on the way out, as it is
  # on the way in.
  defp cast_value(%Date{} = value, :date), do: {:ok, value}
  defp cast_value(%NaiveDateTime{} = value, :datetime), do: {:ok, value}
  defp cast_value(%DateTime{} = value, :datetime), do: {:ok, DateTime.to_naive(value)}
  defp cast_value(%Time{} = value, :time), do: {:ok, value}

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

  # A number as the sheet showed it, never in exponent form: `Kernel.to_string/1` turns
  # 1000.0 into "1.0e3", which is not what anyone typed into a decimal column.
  defp printed(value) when is_integer(value), do: Integer.to_string(value)

  defp printed(value) when is_float(value) do
    # Plain decimals keep a decimal column out of exponent form, which is not what
    # anyone typed there, so they are the form to use wherever they round-trip. But
    # 15 decimals cannot see every value: below about 1.0e-15 they round a nonzero
    # number to "0", and a large magnitude overflows the fixed format and raises.
    # Either way the shortest round-tripping form is written instead, in exponent
    # notation if that is what it takes, since a wrong number and a raised cast are
    # both worse than an exponent.
    with {:ok, fixed} <- fixed_decimals(value),
         true <- round_trips?(fixed, value) do
      fixed
    else
      _ -> :erlang.float_to_binary(value, [:short])
    end
  end

  defp fixed_decimals(value) do
    {:ok, :erlang.float_to_binary(value, [:compact, decimals: 15])}
  rescue
    ArgumentError -> :error
  end

  defp round_trips?(printed, value), do: match?({^value, ""}, Float.parse(printed))

  defp parse(string, parser) do
    case parser.(String.trim(string)) do
      {value, ""} -> {:ok, value}
      _other -> :error
    end
  end

  defp parsed({:ok, value}), do: {:ok, value}
  defp parsed(_other), do: :error

  defp numeric?(string) do
    case Float.parse(String.trim(string)) do
      {_number, ""} -> true
      _other -> false
    end
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
