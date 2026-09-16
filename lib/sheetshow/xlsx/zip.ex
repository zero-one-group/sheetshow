defmodule Sheetshow.Xlsx.Zip do
  @moduledoc false
  # A zip reader and writer that can copy an entry without decompressing it.
  #
  # OTP's `:zip` inflates on read and deflates on write, so rewriting one part
  # of a workbook through it costs the whole file: on a 100 MB workbook that is
  # 16 seconds of zip handling before a single cell is parsed, against a quarter
  # of a second here. That is the only reason this exists. Everything it does
  # beyond that, `:zip` does better.
  #
  # No ZIP64. An xlsx that needs it has passed 4 GB or 65,535 parts, and a
  # reader that half-understands one would give back the wrong bytes rather than
  # an error, so it is refused by name instead.

  alias Sheetshow.Error

  @eocd 0x06054B50
  @eocd64_locator 0x07064B50
  @central 0x02014B50
  @local 0x04034B50

  # The end of central directory record is 22 bytes plus a comment of up to
  # 65,535, and it is the only thing at the end that can be found by scanning.
  @eocd_size 22
  @max_comment 65_535

  @stored 0
  @deflated 8

  @zip64 0xFFFFFFFF
  @zip64_count 0xFFFF

  # Deterministic, so a package written twice is the same bytes: DOS for
  # 1980-01-01 00:00, which is the earliest a zip can name.
  @epoch_time 0
  @epoch_date 0x0021

  defmodule Entry do
    @moduledoc false
    defstruct [:name, :method, :crc, :comp_size, :size, :mtime, :mdate, :data]

    @type t :: %__MODULE__{
            name: String.t(),
            method: non_neg_integer(),
            crc: non_neg_integer(),
            comp_size: non_neg_integer(),
            size: non_neg_integer(),
            mtime: non_neg_integer(),
            mdate: non_neg_integer(),
            data: binary()
          }
  end

  @type t :: [Entry.t()]

  @doc """
  Every entry in the package, in the order the central directory names them,
  each holding its bytes exactly as they are stored, still compressed.
  """
  @spec read(binary()) :: {:ok, t()} | {:error, Error.t()}
  def read(bin) when is_binary(bin) do
    with {:ok, offset, count} <- end_of_central_directory(bin),
         {:ok, central} <- slice(bin, offset, "the central directory") do
      entries(central, count, bin, [])
    end
  end

  @doc """
  The entry's content, inflated.
  """
  @spec fetch(t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def fetch(entries, name) when is_list(entries) and is_binary(name) do
    case Enum.find(entries, &(&1.name == name)) do
      nil -> {:error, missing(name, entries)}
      entry -> inflate(entry)
    end
  end

  @doc """
  Whether the package has an entry by that name.
  """
  @spec member?(t(), String.t()) :: boolean()
  def member?(entries, name) when is_list(entries), do: Enum.any?(entries, &(&1.name == name))

  @doc """
  The entry names, in package order.
  """
  @spec names(t()) :: [String.t()]
  def names(entries) when is_list(entries), do: Enum.map(entries, & &1.name)

  @doc """
  Replaces an entry's content, deflating only this one. An entry that is not
  there is added at the end; one that is keeps its place and its timestamp, so
  a package that has had one part rewritten still lists its parts in the order
  it did before.
  """
  @spec put(t(), String.t(), binary()) :: t()
  def put(entries, name, content) when is_list(entries) and is_binary(content) do
    deflated = deflate(content)

    fresh = fn entry ->
      %{
        (entry || %Entry{name: name, mtime: @epoch_time, mdate: @epoch_date})
        | method: @deflated,
          crc: :erlang.crc32(content),
          comp_size: byte_size(deflated),
          size: byte_size(content),
          data: deflated
      }
    end

    if member?(entries, name) do
      Enum.map(entries, fn entry -> if entry.name == name, do: fresh.(entry), else: entry end)
    else
      entries ++ [fresh.(nil)]
    end
  end

  @doc """
  Drops an entry. Used for `calcChain.xml`, which goes stale the moment a
  formula moves and makes Excel offer to repair the file; it rebuilds it.
  """
  @spec delete(t(), String.t()) :: t()
  def delete(entries, name) when is_list(entries) do
    Enum.reject(entries, &(&1.name == name))
  end

  @doc """
  The package as bytes. Every entry it was given goes out as it came in, except
  the ones `put/3` replaced.
  """
  @spec write(t()) :: {:ok, binary()} | {:error, Error.t()}
  def write(entries) when is_list(entries) do
    with :ok <- writable(entries) do
      {locals, centrals, _offset} =
        Enum.reduce(entries, {[], [], 0}, fn entry, {locals, centrals, offset} ->
          {[local(entry) | locals], [central(entry, offset) | centrals],
           offset + 30 + byte_size(entry.name) + byte_size(entry.data)}
        end)

      locals = Enum.reverse(locals)
      centrals = Enum.reverse(centrals)
      cd_offset = IO.iodata_length(locals)
      cd_size = IO.iodata_length(centrals)
      count = length(entries)

      eocd =
        <<@eocd::little-32, 0::little-16, 0::little-16, count::little-16, count::little-16,
          cd_size::little-32, cd_offset::little-32, 0::little-16>>

      {:ok, IO.iodata_to_binary([locals, centrals, eocd])}
    end
  end

  # --- reading ---

  defp end_of_central_directory(bin) do
    size = byte_size(bin)

    if size < @eocd_size do
      {:error, invalid("it is too short to be a zip file at all")}
    else
      scan_eocd(bin, size - @eocd_size, max(size - @eocd_size - @max_comment, 0))
    end
  end

  defp scan_eocd(_bin, at, floor) when at < floor do
    {:error, invalid("it has no end-of-central-directory record")}
  end

  defp scan_eocd(bin, at, floor) do
    case bin do
      <<_::binary-size(^at), @eocd::little-32, _disk::little-16, _cd_disk::little-16,
        _here::little-16, count::little-16, cd_size::little-32, offset::little-32,
        comment_len::little-16, rest::binary>> ->
        cond do
          byte_size(rest) != comment_len ->
            scan_eocd(bin, at - 1, floor)

          offset == @zip64 or cd_size == @zip64 or count == @zip64_count ->
            {:error, zip64()}

          zip64_locator?(bin, at) ->
            {:error, zip64()}

          true ->
            {:ok, offset, count}
        end

      _ ->
        scan_eocd(bin, at - 1, floor)
    end
  end

  # The locator sits immediately before the record when a zip is ZIP64, even
  # where the counts still fit in the fields that would otherwise give it away.
  defp zip64_locator?(bin, at) when at >= 20 do
    before = at - 20
    match?(<<_::binary-size(^before), @eocd64_locator::little-32, _::binary>>, bin)
  end

  defp zip64_locator?(_bin, _at), do: false

  defp entries(_central, 0, _bin, acc), do: {:ok, Enum.reverse(acc)}

  defp entries(central, remaining, bin, acc) do
    case central do
      <<@central::little-32, _made::little-16, _needed::little-16, flags::little-16,
        method::little-16, mtime::little-16, mdate::little-16, crc::little-32,
        comp_size::little-32, size::little-32, name_len::little-16, extra_len::little-16,
        comment_len::little-16, _disk::little-16, _internal::little-16, _external::little-32,
        local_offset::little-32, tail::binary>> ->
        with {:ok, name, rest} <- name_and_skip(tail, name_len, extra_len + comment_len),
             :ok <- readable(flags, name, comp_size, size, local_offset),
             {:ok, data} <- raw(bin, local_offset, comp_size, name) do
          entry = %Entry{
            name: name,
            method: method,
            crc: crc,
            comp_size: comp_size,
            size: size,
            mtime: mtime,
            mdate: mdate,
            data: data
          }

          entries(rest, remaining - 1, bin, [entry | acc])
        end

      _ ->
        {:error, invalid("its central directory ends before it says it does")}
    end
  end

  defp name_and_skip(tail, name_len, skip) do
    case tail do
      <<name::binary-size(^name_len), _::binary-size(^skip), rest::binary>> ->
        {:ok, name, rest}

      _ ->
        {:error, invalid("an entry name runs past the end of the central directory")}
    end
  end

  # Bit 0 is encryption; a ZIP64 entry hides its real sizes behind sentinels in
  # the extra field, which is exactly the case where guessing would hand back
  # the wrong bytes without saying so.
  defp readable(flags, name, comp_size, size, local_offset) do
    cond do
      rem(flags, 2) == 1 ->
        {:error,
         Error.new(:unsupported, "#{name} is encrypted, and Sheetshow does not decrypt",
           entry: name
         )}

      comp_size == @zip64 or size == @zip64 or local_offset == @zip64 ->
        {:error, zip64()}

      true ->
        :ok
    end
  end

  # The local header's name and extra lengths can differ from the central
  # directory's, so the data's offset is worked out from the header that is
  # actually in front of it. Its sizes are not read at all: with a data
  # descriptor they are zero, and the central directory's are the true ones.
  defp raw(bin, offset, comp_size, name) do
    case bin do
      <<_::binary-size(^offset), @local::little-32, _version::little-16, _flags::little-16,
        _method::little-16, _mtime::little-16, _mdate::little-16, _crc::little-32,
        _comp::little-32, _size::little-32, name_len::little-16, extra_len::little-16,
        rest::binary>> ->
        skip = name_len + extra_len

        case rest do
          <<_::binary-size(^skip), data::binary-size(^comp_size), _::binary>> ->
            {:ok, data}

          _ ->
            {:error, invalid("#{name} runs past the end of the file")}
        end

      _ ->
        {:error, invalid("#{name} has no local header where the central directory says it does")}
    end
  end

  defp slice(bin, offset, what) do
    case bin do
      <<_::binary-size(^offset), rest::binary>> -> {:ok, rest}
      _ -> {:error, invalid("#{what} starts past the end of the file")}
    end
  end

  defp inflate(%Entry{method: @stored} = entry), do: {:ok, entry.data}

  defp inflate(%Entry{method: @deflated} = entry) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      content = z |> :zlib.inflate(entry.data) |> IO.iodata_to_binary()
      :zlib.inflateEnd(z)
      {:ok, content}
    rescue
      ErlangError ->
        {:error, invalid("#{entry.name} does not inflate: the file is damaged")}
    after
      :zlib.close(z)
    end
  end

  defp inflate(%Entry{} = entry) do
    {:error,
     Error.new(
       :unsupported,
       "#{entry.name} is stored with compression method #{entry.method}, " <>
         "and Sheetshow reads only stored and deflated entries",
       entry: entry.name,
       method: entry.method
     )}
  end

  # --- writing ---

  defp deflate(content) do
    z = :zlib.open()

    try do
      :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
      out = z |> :zlib.deflate(content, :finish) |> IO.iodata_to_binary()
      :zlib.deflateEnd(z)
      out
    after
      :zlib.close(z)
    end
  end

  defp local(%Entry{} = entry) do
    [
      <<@local::little-32, 20::little-16, 0::little-16, entry.method::little-16,
        entry.mtime::little-16, entry.mdate::little-16, entry.crc::little-32,
        entry.comp_size::little-32, entry.size::little-32, byte_size(entry.name)::little-16,
        0::little-16>>,
      entry.name,
      entry.data
    ]
  end

  defp central(%Entry{} = entry, offset) do
    [
      <<@central::little-32, 20::little-16, 20::little-16, 0::little-16, entry.method::little-16,
        entry.mtime::little-16, entry.mdate::little-16, entry.crc::little-32,
        entry.comp_size::little-32, entry.size::little-32, byte_size(entry.name)::little-16,
        0::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-32, offset::little-32>>,
      entry.name
    ]
  end

  # What would need ZIP64 to say. Refused here rather than written wrong.
  defp writable(entries) do
    total =
      Enum.reduce(entries, 0, fn entry, acc ->
        acc + 76 + 2 * byte_size(entry.name) + byte_size(entry.data)
      end)

    cond do
      length(entries) > @zip64_count ->
        {:error, zip64("it would hold more than #{@zip64_count} parts")}

      total >= @zip64 ->
        {:error, zip64("it would be larger than 4 GB")}

      true ->
        :ok
    end
  end

  # --- errors ---

  defp invalid(why),
    do: Error.new(:invalid_zip, "this is not a zip file Sheetshow can read: #{why}")

  defp zip64(why \\ "it uses ZIP64") do
    Error.new(
      :unsupported,
      "#{why}, and Sheetshow does not read or write ZIP64. A spreadsheet this " <>
        "large is past what a spreadsheet is for."
    )
  end

  defp missing(name, entries) do
    Error.new(:unknown_entry, "there is no #{name} in this package",
      entry: name,
      entries: names(entries)
    )
  end
end
