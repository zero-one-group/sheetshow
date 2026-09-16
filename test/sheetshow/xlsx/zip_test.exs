defmodule Sheetshow.Xlsx.ZipTest do
  use ExUnit.Case, async: true

  alias Sheetshow.Error
  alias Sheetshow.Xlsx.Zip

  # OTP's :zip is the other implementation to check against: what it writes,
  # this has to read, and what this writes, it has to read back.
  defp zipped(files, opts \\ []) do
    files = Enum.map(files, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, {_name, bin}} = :zip.create(~c"t.zip", files, [:memory | opts])
    bin
  end

  defp extracted(bin) do
    {:ok, files} = :zip.extract(bin, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), content} end)
  end

  defp parts do
    [
      {"[Content_Types].xml", "<Types/>"},
      {"xl/workbook.xml", "<workbook/>"},
      {"xl/worksheets/sheet1.xml", String.duplicate("<row/>", 500)},
      {"xl/worksheets/sheet2.xml", String.duplicate("<cell/>", 500)}
    ]
  end

  # The central directory's offset, as the end-of-central-directory names it.
  defp central_offset(bin) do
    at = byte_size(bin) - 22
    <<_::binary-size(^at), _::binary-size(16), offset::little-32, _::binary>> = bin
    offset
  end

  defp patch(bin, offset, replacement) do
    size = byte_size(replacement)
    <<before::binary-size(^offset), _::binary-size(^size), rest::binary>> = bin
    before <> replacement <> rest
  end

  describe "reading what :zip wrote" do
    test "every part, in the order the package lists them" do
      {:ok, entries} = Zip.read(zipped(parts()))

      assert Zip.names(entries) == [
               "[Content_Types].xml",
               "xl/workbook.xml",
               "xl/worksheets/sheet1.xml",
               "xl/worksheets/sheet2.xml"
             ]
    end

    test "a part's content comes back as it went in" do
      {:ok, entries} = Zip.read(zipped(parts()))

      for {name, content} <- parts() do
        assert {:ok, ^content} = Zip.fetch(entries, name)
      end
    end

    test "entries are held still compressed, which is the point of all this" do
      {:ok, entries} = Zip.read(zipped(parts()))
      sheet = Enum.find(entries, &(&1.name == "xl/worksheets/sheet1.xml"))

      assert sheet.method == 8
      assert sheet.comp_size < sheet.size
      assert byte_size(sheet.data) == sheet.comp_size
    end

    test "a stored part is read too, and needs no inflating" do
      {:ok, entries} = Zip.read(zipped(parts(), [{:compress, []}]))
      sheet = Enum.find(entries, &(&1.name == "xl/worksheets/sheet1.xml"))

      assert sheet.method == 0
      assert sheet.comp_size == sheet.size
      assert {:ok, content} = Zip.fetch(entries, "xl/worksheets/sheet1.xml")
      assert content == String.duplicate("<row/>", 500)
    end

    test "a package with a trailing comment is still found" do
      commented = zipped(parts()) |> patch(byte_size(zipped(parts())) - 2, <<5::little-16>>)
      commented = commented <> "hello"

      assert {:ok, entries} = Zip.read(commented)
      assert length(entries) == 4
    end

    test "member? and names say what is there without inflating anything" do
      {:ok, entries} = Zip.read(zipped(parts()))

      assert Zip.member?(entries, "xl/workbook.xml")
      refute Zip.member?(entries, "xl/styles.xml")
    end
  end

  describe "writing something :zip can read" do
    test "a package read and written unchanged still holds every part" do
      {:ok, entries} = Zip.read(zipped(parts()))
      assert {:ok, bin} = Zip.write(entries)

      assert extracted(bin) == Map.new(parts())
    end

    test "the same entries written twice are the same bytes" do
      {:ok, entries} = Zip.read(zipped(parts()))
      assert {:ok, once} = Zip.write(entries)
      assert {:ok, twice} = Zip.write(entries)

      assert once == twice
    end

    test "a part put back is what comes out" do
      {:ok, entries} = Zip.read(zipped(parts()))

      assert {:ok, bin} =
               entries |> Zip.put("xl/worksheets/sheet1.xml", "<rewritten/>") |> Zip.write()

      assert extracted(bin)["xl/worksheets/sheet1.xml"] == "<rewritten/>"
    end

    test "a part that was not there is added at the end" do
      {:ok, entries} = Zip.read(zipped(parts()))
      entries = Zip.put(entries, "xl/styles.xml", "<styleSheet/>")

      assert List.last(Zip.names(entries)) == "xl/styles.xml"
      assert {:ok, bin} = Zip.write(entries)
      assert extracted(bin)["xl/styles.xml"] == "<styleSheet/>"
    end

    test "a part can be dropped, which is what calcChain.xml needs" do
      {:ok, entries} = Zip.read(zipped(parts() ++ [{"xl/calcChain.xml", "<calcChain/>"}]))
      entries = Zip.delete(entries, "xl/calcChain.xml")

      refute Zip.member?(entries, "xl/calcChain.xml")
      assert {:ok, bin} = Zip.write(entries)
      refute Map.has_key?(extracted(bin), "xl/calcChain.xml")
    end

    test "a stored part stays stored rather than being deflated on the way out" do
      {:ok, entries} = Zip.read(zipped(parts(), [{:compress, []}]))
      assert {:ok, bin} = Zip.write(entries)

      {:ok, again} = Zip.read(bin)
      assert Enum.all?(again, &(&1.method == 0))
      assert extracted(bin) == Map.new(parts())
    end
  end

  describe "passthrough" do
    setup do
      {:ok, before} = Zip.read(zipped(parts()))
      {:ok, bin} = before |> Zip.put("xl/worksheets/sheet1.xml", "<rewritten/>") |> Zip.write()
      {:ok, after_} = Zip.read(bin)

      %{before: before, after: after_, bin: bin}
    end

    test "every part but the one touched is byte-identical, still compressed", ctx do
      before = Map.new(ctx.before, &{&1.name, &1})
      rewritten = Map.new(ctx.after, &{&1.name, &1})

      for name <- Zip.names(ctx.before), name != "xl/worksheets/sheet1.xml" do
        assert rewritten[name].data == before[name].data, "#{name} was not copied verbatim"
        assert rewritten[name].crc == before[name].crc
        assert rewritten[name].comp_size == before[name].comp_size
        assert rewritten[name].size == before[name].size
      end
    end

    test "the package still lists its parts in the order it did", ctx do
      assert Zip.names(ctx.after) == Zip.names(ctx.before)
    end

    test "a replaced part keeps its place rather than moving to the end", ctx do
      assert Enum.at(Zip.names(ctx.after), 2) == "xl/worksheets/sheet1.xml"
    end

    test "and the whole thing is still a zip by :zip's reckoning", ctx do
      assert extracted(ctx.bin)["xl/worksheets/sheet1.xml"] == "<rewritten/>"
      assert extracted(ctx.bin)["xl/workbook.xml"] == "<workbook/>"
    end
  end

  describe "what it refuses" do
    test "something that is not a zip at all" do
      assert {:error, %Error{reason: :invalid_zip} = error} =
               Zip.read("not a zip, just some text")

      assert Exception.message(error) =~ "no end-of-central-directory"
    end

    test "something far too short to be one" do
      assert {:error, %Error{reason: :invalid_zip} = error} = Zip.read("PK")
      assert Exception.message(error) =~ "too short"
    end

    test "a package whose central directory has been cut off" do
      bin = zipped(parts())
      truncated = patch(bin, byte_size(bin) - 6, <<byte_size(bin) * 2::little-32>>)

      assert {:error, %Error{reason: :invalid_zip}} = Zip.read(truncated)
    end

    test "a package whose entry points past the end of the file" do
      bin = zipped(parts())
      at = central_offset(bin) + 42

      assert {:error, %Error{reason: :invalid_zip} = error} =
               Zip.read(patch(bin, at, <<byte_size(bin) * 2::little-32>>))

      assert Exception.message(error) =~ "local header"
    end

    test "ZIP64, by its sentinel offset" do
      bin = zipped(parts())
      at = byte_size(bin) - 22 + 16

      assert {:error, %Error{reason: :unsupported} = error} =
               Zip.read(patch(bin, at, <<0xFFFFFFFF::little-32>>))

      assert Exception.message(error) =~ "ZIP64"
    end

    test "ZIP64, by the locator that sits in front of the record" do
      bin = zipped(parts())
      at = byte_size(bin) - 22
      <<before::binary-size(^at), eocd::binary>> = bin
      locator = <<0x07064B50::little-32, 0::little-32, 0::little-64, 1::little-32>>

      assert {:error, %Error{reason: :unsupported}} = Zip.read(before <> locator <> eocd)
    end

    test "an encrypted entry, rather than handing back the ciphertext" do
      bin = zipped(parts())
      at = central_offset(bin) + 8

      assert {:error, %Error{reason: :unsupported} = error} =
               Zip.read(patch(bin, at, <<1::little-16>>))

      assert Exception.message(error) =~ "encrypted"
    end

    test "inflating an entry stored by some method we do not know" do
      bin = zipped(parts())
      at = central_offset(bin) + 10

      # Reading the package is still fine: an entry we cannot inflate can still
      # be copied through untouched, which is most of what happens to them.
      assert {:ok, entries} = Zip.read(patch(bin, at, <<99::little-16>>))

      assert {:error, %Error{reason: :unsupported} = error} =
               Zip.fetch(entries, "[Content_Types].xml")

      assert Exception.message(error) =~ "compression method 99"
    end

    test "a part that is not in the package" do
      {:ok, entries} = Zip.read(zipped(parts()))

      assert {:error, %Error{reason: :unknown_entry} = error} = Zip.fetch(entries, "xl/nope.xml")
      assert error.details.entry == "xl/nope.xml"
      assert "xl/workbook.xml" in error.details.entries
    end

    test "a part whose bytes are damaged" do
      {:ok, entries} = Zip.read(zipped(parts()))

      broken =
        Enum.map(entries, fn entry ->
          if entry.name == "xl/worksheets/sheet1.xml",
            do: %{entry | data: :binary.copy(<<0>>, entry.comp_size)},
            else: entry
        end)

      assert {:error, %Error{reason: :invalid_zip} = error} =
               Zip.fetch(broken, "xl/worksheets/sheet1.xml")

      assert Exception.message(error) =~ "does not inflate"
    end

    test "writing a package with more parts than a zip can name" do
      entries = for i <- 1..65_536, do: %Zip.Entry{name: "p#{i}", data: "", comp_size: 0, size: 0}

      assert {:error, %Error{reason: :unsupported} = error} = Zip.write(entries)
      assert Exception.message(error) =~ "65535 parts"
    end
  end
end
