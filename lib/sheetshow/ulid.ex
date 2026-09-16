defmodule Sheetshow.ULID do
  @moduledoc """
  Identifiers that sort by the time they were made.

  A ULID is 26 characters: 48 bits of milliseconds since the epoch, then 80
  more, in Crockford's base32. Sorting a column of them puts the log in the
  order it was written, they are short enough to read in a cell, and the client
  makes them, which is what lets a write be retried, since the same id appended
  twice folds to one row.

  The 80 bits are usually all random. Here the first ten of them are the
  microsecond within the millisecond, and the other seventy are random, so two
  ids made a microsecond apart sort in the order they were made without any
  process having to remember the last one it handed out. A batch of events
  written in one go therefore reads back in write order on a tab sorted by id,
  which is what `Sheetshow.Log.view/2` sorts by. The cost is ten bits of
  randomness and an id that is a ULID to every reader but not quite to the
  letter of the spec.

      iex> Sheetshow.ULID.generate() |> byte_size()
      26

  A log does not insist on these: any non-empty string works as an id, so an
  invoice number or a UUID your app already has is fine. This is only what
  `Sheetshow.Log.Event.new/2` reaches for when you give it nothing.
  """

  @crockford "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @values for {char, value} <- Enum.with_index(~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"),
              into: %{},
              do: {char, value}

  @doc """
  A new identifier, timed by the system clock in microseconds unless you say
  otherwise.

  Two made in the same microsecond sort by their random half; two made a
  microsecond apart sort in that order.

      iex> Sheetshow.ULID.generate(0) |> binary_part(0, 10)
      "0000000000"
      iex> Sheetshow.ULID.generate(1_700_000_000_000_001) < Sheetshow.ULID.generate(1_700_000_000_000_002)
      true
  """
  @spec generate(integer()) :: String.t()
  def generate(time \\ System.system_time(:microsecond)) when is_integer(time) do
    <<random::70, _::2>> = :crypto.strong_rand_bytes(9)
    encode(<<0::2, div(time, 1000)::48, rem(time, 1000)::10, random::70>>)
  end

  @doc """
  Whether the string is one of ours: 26 canonical characters, and a first one
  low enough that the time fits in 48 bits.

      iex> Sheetshow.ULID.generate() |> Sheetshow.ULID.valid?()
      true
      iex> Sheetshow.ULID.valid?("invoice-104")
      false
  """
  @spec valid?(term()) :: boolean()
  def valid?(ulid) when is_binary(ulid) and byte_size(ulid) == 26 do
    :binary.first(ulid) in ?0..?7 and
      Enum.all?(:binary.bin_to_list(ulid), &Map.has_key?(@values, &1))
  end

  def valid?(_other), do: false

  @doc """
  The moment an identifier was made. Raises `ArgumentError` for anything that
  is not one.

      iex> Sheetshow.ULID.generate(0) |> Sheetshow.ULID.timestamp()
      ~U[1970-01-01 00:00:00.000Z]
  """
  @spec timestamp(String.t()) :: DateTime.t()
  def timestamp(ulid) do
    if not valid?(ulid) do
      raise ArgumentError, "not a ULID: #{inspect(ulid)}"
    end

    <<_pad::2, milliseconds::48>> = decode(binary_part(ulid, 0, 10))
    DateTime.from_unix!(milliseconds, :millisecond)
  end

  defp encode(bits) do
    for <<value::5 <- bits>>, into: "", do: <<:binary.at(@crockford, value)>>
  end

  defp decode(string) do
    for <<char <- string>>, into: <<>>, do: <<Map.fetch!(@values, char)::5>>
  end
end
