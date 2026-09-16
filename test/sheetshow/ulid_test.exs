defmodule Sheetshow.ULIDTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.ULID

  alias Sheetshow.ULID

  describe "generate/1" do
    test "is 26 canonical characters" do
      ulid = ULID.generate()

      assert byte_size(ulid) == 26
      assert ULID.valid?(ulid)
      assert ulid == String.upcase(ulid)
    end

    test "never repeats itself" do
      ulids = for _ <- 1..1_000, do: ULID.generate()

      assert ulids |> Enum.uniq() |> length() == 1_000
    end

    test "sorts by the moment it was made, down to the microsecond" do
      early = ULID.generate(1_600_000_000_000_000)
      later = ULID.generate(1_600_000_000_000_001)
      late = ULID.generate(1_600_000_000_001_000)

      assert early < later and later < late
    end

    test "a batch made in one millisecond reads back in the order it was made" do
      ids = for micro <- 0..999, do: ULID.generate(1_600_000_000_000_000 + micro)

      assert Enum.sort(ids) == ids
    end

    test "two in the same microsecond share a prefix and still differ" do
      a = ULID.generate(1_600_000_000_000_000)
      b = ULID.generate(1_600_000_000_000_000)

      assert binary_part(a, 0, 12) == binary_part(b, 0, 12)
      assert a != b
    end

    test "the time survives the round trip, to the millisecond" do
      time = DateTime.utc_now() |> DateTime.truncate(:millisecond)
      microseconds = DateTime.to_unix(time, :microsecond) + 999

      assert microseconds |> ULID.generate() |> ULID.timestamp() == time
    end
  end

  describe "valid?/1" do
    test "refuses the wrong length, the ambiguous letters and anything else" do
      refute ULID.valid?("")
      refute ULID.valid?(String.duplicate("0", 25))
      refute ULID.valid?(String.duplicate("0", 27))
      # I, L, O and U are left out of Crockford's alphabet on purpose.
      refute ULID.valid?(String.duplicate("0", 25) <> "I")
      refute ULID.valid?(String.downcase(ULID.generate()))
      refute ULID.valid?(:not_a_string)
    end

    test "refuses a first character that would overflow the timestamp" do
      refute ULID.valid?("8" <> String.duplicate("0", 25))
      assert ULID.valid?("7" <> String.duplicate("0", 25))
    end
  end

  describe "timestamp/1" do
    test "raises on anything that is not a ULID" do
      assert_raise ArgumentError, ~r/not a ULID/, fn -> ULID.timestamp("invoice-104") end
    end
  end
end
