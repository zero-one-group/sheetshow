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
end
