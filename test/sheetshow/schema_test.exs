defmodule Sheetshow.SchemaTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.Schema

  alias Sheetshow.{Error, Schema}

  describe "validate/1" do
    test "takes a keyword list of known types" do
      assert Schema.validate(item: :string, cost: :decimal, on: :date) == :ok
    end

    test "refuses an empty schema, a map, and a list that is not one" do
      assert {:error, %Error{reason: :invalid_schema}} = Schema.validate([])
      assert {:error, %Error{reason: :invalid_schema}} = Schema.validate(%{item: :string})
      assert {:error, %Error{reason: :invalid_schema}} = Schema.validate([:item])
    end

    test "refuses an unknown type and names it" do
      assert {:error, %Error{reason: :invalid_schema, message: message}} =
               Schema.validate(item: :text)

      assert message =~ ":text"
    end

    test "refuses the same column twice" do
      assert {:error, %Error{reason: :invalid_schema, message: message}} =
               Schema.validate(item: :string, item: :integer)

      assert message =~ ":item"
    end

    test "refuses a column whose name is blank once trimmed" do
      assert {:error, %Error{reason: :invalid_schema, message: message}} =
               Schema.validate([{:"  ", :string}])

      assert message =~ "no name"
    end

    test "refuses two columns that differ only by case or surrounding space" do
      # A header is matched case- and space-insensitively, so these are one
      # column, and one would silently overwrite the other.
      assert {:error, %Error{reason: :invalid_schema, message: message}} =
               Schema.validate(name: :string, Name: :integer)

      assert message =~ ":name"

      assert {:error, %Error{reason: :invalid_schema}} =
               Schema.validate([{:"a ", :string}, {:a, :integer}])
    end
  end

  describe "encode/2" do
    test "puts the values in schema order, with nil for what the record leaves out" do
      assert Schema.encode(%{cost: 12}, item: :string, cost: :integer) == {:ok, [nil, 12]}
    end

    test "takes every type" do
      schema = [
        a: :string,
        b: :integer,
        c: :float,
        d: :boolean,
        e: :date,
        f: :datetime,
        g: :time,
        h: :decimal,
        i: :json
      ]

      record = %{
        a: "text",
        b: 42,
        c: 2.5,
        d: true,
        e: ~D[2026-09-13],
        f: ~N[2026-09-13 08:30:00],
        g: ~T[08:30:00],
        h: "1000.00",
        i: %{"nested" => [1, 2]}
      }

      assert {:ok, values} = Schema.encode(record, schema)

      assert values == [
               "text",
               42,
               2.5,
               true,
               ~D[2026-09-13],
               ~N[2026-09-13 08:30:00],
               ~T[08:30:00],
               "1000.00",
               ~s({"nested":[1,2]})
             ]
    end

    test "an integer in a float column is written as a float" do
      assert Schema.encode(%{rate: 1}, rate: :float) == {:ok, [1.0]}
    end

    test "refuses a value of the wrong type and says which column" do
      assert {:error, %Error{reason: :invalid_record, details: details}} =
               Schema.encode(%{cost: "free"}, cost: :integer)

      assert details == %{column: :cost, type: :integer, value: "free"}
    end

    test "refuses a decimal that is not a number, because the sheet would keep the typo" do
      assert {:error, %Error{reason: :invalid_record}} =
               Schema.encode(%{cost: "1,000"}, cost: :decimal)

      assert Schema.encode(%{cost: "-1.5e3"}, cost: :decimal) == {:ok, ["-1.5e3"]}
    end

    test "refuses a term JSON cannot hold" do
      assert {:error, %Error{reason: :invalid_record}} =
               Schema.encode(%{blob: {1, 2}}, blob: :json)
    end

    test "refuses a key the schema has no column for" do
      assert {:error, %Error{reason: :unknown_column, details: %{column: :cost}}} =
               Schema.encode(%{item: "Rent", cost: 1}, item: :string)
    end

    test "a float is not an integer, so rounding is never done behind your back" do
      assert {:error, %Error{reason: :invalid_record}} = Schema.encode(%{n: 1.0}, n: :integer)
    end
  end

  describe "cast/2" do
    test "an empty cell is nil, not an error" do
      assert Schema.cast([nil, ""], item: :string, cost: :integer) ==
               {%{item: nil, cost: nil}, %{}}
    end

    test "a short row is padded, because Sheets drops trailing empties" do
      assert Schema.cast(["Rent"], item: :string, cost: :integer) ==
               {%{item: "Rent", cost: nil}, %{}}
    end

    test "takes what Sheets would have coerced" do
      assert {%{n: 42}, %{}} = Schema.cast([42.0], n: :integer)
      assert {%{n: 42}, %{}} = Schema.cast(["42"], n: :integer)
      assert {%{r: 2.5}, %{}} = Schema.cast(["2.5"], r: :float)
      assert {%{r: 2.0}, %{}} = Schema.cast([2], r: :float)
      assert {%{s: "42"}, %{}} = Schema.cast([42], s: :string)
      assert {%{b: true}, %{}} = Schema.cast(["TRUE"], b: :boolean)
      assert {%{b: false}, %{}} = Schema.cast(["no"], b: :boolean)
    end

    test "reads a serial number as the temporal kind the column says" do
      assert {%{on: ~D[2026-09-12]}, %{}} = Schema.cast([46_277], on: :date)

      assert {%{at: ~N[2026-09-12 08:30:00]}, %{}} =
               Schema.cast([46_277.354166666664], at: :datetime)

      assert {%{at: ~T[08:30:00]}, %{}} = Schema.cast([0.3541666666666667], at: :time)
    end

    test "reads an ISO string too, since that is what a person types" do
      assert {%{on: ~D[2026-09-12]}, %{}} = Schema.cast(["2026-09-12"], on: :date)

      assert {%{at: ~N[2026-09-12 08:30:00]}, %{}} =
               Schema.cast(["2026-09-12T08:30:00"], at: :datetime)
    end

    test "keeps a decimal as the text it was written as" do
      assert {%{cost: "1000.00"}, %{}} = Schema.cast(["1000.00"], cost: :decimal)
    end

    test "a decimal someone typed as a number comes back as a number would print" do
      assert {%{cost: "1000.0"}, %{}} = Schema.cast([1000.0], cost: :decimal)
    end

    test "a tiny number in a decimal column keeps its value rather than becoming 0" do
      # 15 fixed decimals rounded it to "0"; the shortest round-tripping form is
      # kept instead, exponent and all.
      assert {%{cost: "1.0e-20"}, %{}} = Schema.cast([1.0e-20], cost: :decimal)
    end

    test "a serial too large to convert is a cast error, not a crash" do
      assert {%{d: nil}, %{d: %Error{reason: :cast}}} = Schema.cast([1.0e308], d: :date)
    end

    test "decodes json" do
      assert {%{blob: %{"a" => 1}}, %{}} = Schema.cast([~s({"a":1})], blob: :json)
    end

    test "a json scalar somebody typed by hand is the number or boolean Sheets made of it" do
      assert {%{blob: 42}, %{}} = Schema.cast([42], blob: :json)
      assert {%{blob: true}, %{}} = Schema.cast([true], blob: :json)
      assert {%{blob: 2.5}, %{}} = Schema.cast(["2.5"], blob: :json)
    end

    test "the temporal kinds arrive already made from a backend that keeps values" do
      assert {%{on: ~D[2026-09-12]}, %{}} = Schema.cast([~D[2026-09-12]], on: :date)

      assert {%{at: ~N[2026-09-12 08:30:00]}, %{}} =
               Schema.cast([~N[2026-09-12 08:30:00]], at: :datetime)

      assert {%{at: ~N[2026-09-12 08:30:00]}, %{}} =
               Schema.cast([~U[2026-09-12 08:30:00Z]], at: :datetime)

      assert {%{at: ~T[08:30:00]}, %{}} = Schema.cast([~T[08:30:00]], at: :time)
      assert {%{at: ~T[08:30:00]}, %{}} = Schema.cast(["08:30:00"], at: :time)
    end

    test "a boolean in a string column reads as Sheets shows it" do
      assert {%{s: "TRUE"}, %{}} = Schema.cast([true], s: :string)
      assert {%{s: "FALSE"}, %{}} = Schema.cast([false], s: :string)
    end

    test "a DateTime is written to a datetime column as its wall-clock time" do
      assert {:ok, [~U[2026-09-12 08:30:00Z]]} =
               Schema.encode(%{at: ~U[2026-09-12 08:30:00Z]}, at: :datetime)
    end

    test "flags the cell it could not read and leaves the field nil" do
      assert {record, errors} = Schema.cast(["Rent", "free"], item: :string, cost: :integer)

      assert record == %{item: "Rent", cost: nil}
      assert %{cost: %Error{reason: :cast, details: details}} = errors
      assert details == %{column: :cost, type: :integer, value: "free"}
      refute Map.has_key?(errors, :item)
    end

    test "a fraction is not an integer" do
      assert {%{n: nil}, %{n: %Error{}}} = Schema.cast([2.5], n: :integer)
    end

    test "refuses a word it cannot read as a boolean rather than guessing" do
      assert {%{b: nil}, %{b: %Error{}}} = Schema.cast(["perhaps"], b: :boolean)
    end

    test "a blank boolean column is nil, not false: the column says nothing" do
      assert {%{b: nil}, %{}} = Schema.cast([""], b: :boolean)
    end
  end

  describe "cast_boolean/1" do
    test "blank is false, which is what a log's deleted flag wants" do
      assert Schema.cast_boolean(nil) == {:ok, false}
      assert Schema.cast_boolean("") == {:ok, false}
      assert Schema.cast_boolean("   ") == {:ok, false}
    end

    test "takes what a sheet and a person both write" do
      assert Schema.cast_boolean(true) == {:ok, true}
      assert Schema.cast_boolean("true") == {:ok, true}
      assert Schema.cast_boolean("Yes") == {:ok, true}
      assert Schema.cast_boolean(1) == {:ok, true}
      assert Schema.cast_boolean(false) == {:ok, false}
      assert Schema.cast_boolean("FALSE") == {:ok, false}
      assert Schema.cast_boolean(0) == {:ok, false}
    end

    test "a one or a zero a backend kept as a float" do
      assert Schema.cast_boolean(1.0) == {:ok, true}
      assert Schema.cast_boolean(0.0) == {:ok, false}
      assert Schema.cast_boolean(2) == :error
    end
  end
end
