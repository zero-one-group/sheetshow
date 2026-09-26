defmodule Sheetshow.ValueTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.Value

  alias Sheetshow.Value

  @valid [
    {nil, :empty},
    {0, :number},
    {-1.5, :number},
    {"", :string},
    {"text", :string},
    {true, :boolean},
    {false, :boolean},
    {{:formula, "=1+1"}, :formula},
    {~D[2026-09-12], :date},
    {~N[2026-09-12 08:30:00], :datetime},
    {~U[2026-09-12 08:30:00Z], :datetime},
    {~T[08:30:00], :time}
  ]

  @invalid [:atom, {:formula, "1+1"}, {:formula, nil}, [1], %{}, {1, 2}, self(), ~c"charlist"]

  test "kind and validate agree on valid values" do
    for {value, kind} <- @valid do
      assert Value.kind(value) == kind
      assert Value.validate(value) == :ok
      assert Value.valid?(value)
    end
  end

  test "invalid values are rejected everywhere" do
    for value <- @invalid do
      assert_raise ArgumentError, fn -> Value.kind(value) end

      assert {:error, %Sheetshow.Error{reason: :invalid_value, details: %{value: ^value}}} =
               Value.validate(value)

      refute Value.valid?(value)
    end
  end

  describe "serial numbers" do
    test "anchors" do
      assert Value.to_serial(~D[1899-12-30]) == 0
      assert Value.to_serial(~D[1900-01-01]) == 2
      assert Value.to_serial(~D[2024-01-01]) == 45292
      assert Value.to_serial(~N[2024-01-01 06:00:00]) == 45292.25
      assert Value.to_serial(~D[1899-12-29]) == -1
      assert Value.to_serial(~T[00:00:00]) == 0.0
    end

    test "a DateTime is written as its wall-clock time" do
      jakarta = DateTime.from_naive!(~N[2026-09-12 08:30:00], "Etc/UTC") |> DateTime.add(7 * 3600)
      assert Value.to_serial(jakarta) == Value.to_serial(DateTime.to_naive(jakarta))
    end

    test "dates round-trip, including before the epoch" do
      for date <- [~D[1899-12-30], ~D[1899-12-29], ~D[1800-02-28], ~D[1970-01-01], ~D[2100-12-31]] do
        assert date |> Value.to_serial() |> Value.from_serial(:date) == date
      end
    end

    test "second-precision datetimes and times round-trip as ==" do
      for ndt <- [
            ~N[2024-01-01 00:00:00],
            ~N[2024-01-01 23:59:59],
            ~N[1899-12-29 13:00:01],
            ~N[2026-09-12 08:30:07],
            ~N[2099-06-30 10:30:01]
          ] do
        assert ndt |> Value.to_serial() |> Value.from_serial(:datetime) == ndt
        time = NaiveDateTime.to_time(ndt)
        assert time |> Value.to_serial() |> Value.from_serial(:time) == time
      end
    end

    test "milliseconds survive; finer precision rounds to the millisecond" do
      assert ~N[2024-01-01 12:00:00.500] |> Value.to_serial() |> Value.from_serial(:datetime) ==
               ~N[2024-01-01 12:00:00.500]

      assert ~N[2024-01-01 12:00:00.123456] |> Value.to_serial() |> Value.from_serial(:datetime) ==
               ~N[2024-01-01 12:00:00.123]
    end

    test "a datetime serial truncates to its date" do
      assert Value.from_serial(45292.99, :date) == ~D[2024-01-01]
      assert Value.from_serial(-0.5, :date) == ~D[1899-12-29]
    end
  end

  test "default number formats exist for temporal kinds only" do
    assert Value.default_number_format(~N[2026-09-12 08:30:00]) == "yyyy-mm-dd hh:mm:ss"
    assert Value.default_number_format(~T[08:30:00]) == "hh:mm:ss"

    for value <- [nil, 1, "x", true, {:formula, "=1"}],
        do: assert(Value.default_number_format(value) == nil)
  end

  describe "the 0.1.6 review" do
    test "text must be UTF-8 to be a value" do
      refute Value.valid?(<<"Caf", 233>>)
      refute Value.valid?({:formula, <<"=\"", 233, "\"">>})

      assert {:error, %Sheetshow.Error{reason: :invalid_value} = error} =
               Value.validate(<<"Caf", 233>>)

      assert Exception.message(error) =~ "UTF-8"
      assert Value.valid?("Café")
    end

    test "a serial outside the years a date holds raises at once, rather than never returning" do
      task =
        Task.async(fn ->
          try do
            Value.from_serial(1.0e16, :date)
          rescue
            error -> error
          end
        end)

      assert %ArgumentError{} = Task.await(task, 2_000)

      for serial <- [1.0e308, -1.0e7, 2_958_466] do
        assert_raise ArgumentError, fn -> Value.from_serial(serial, :datetime) end
      end

      assert Value.from_serial(2_958_465.5, :datetime) == ~N[9999-12-31 12:00:00]
      assert_raise ArgumentError, fn -> Value.from_serial(2_958_465.999999995, :date) end
      assert Value.read_serial(2_958_465.999999995, :datetime) == 2_958_465.999999995
      assert Value.from_serial(-693_593, :date) == ~D[0001-01-01]
    end

    test "a time a hair before midnight stays on its own day" do
      assert Value.from_serial(0.9999999999, :time) == ~T[23:59:59.999]
    end

    test "a format that shows only part of a moment does not lose the rest" do
      assert Value.read_serial(45_292, :date) == ~D[2024-01-01]
      assert Value.read_serial(45_292.75, :date) == ~N[2024-01-01 18:00:00]
      assert Value.read_serial(0.75, :time) == ~T[18:00:00]
      assert Value.read_serial(45_292.75, :time) == ~N[2024-01-01 18:00:00]
      assert Value.read_serial(1.0e20, :date) == 1.0e20
    end
  end
end
