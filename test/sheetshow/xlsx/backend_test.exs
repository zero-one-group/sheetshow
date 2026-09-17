defmodule Sheetshow.Xlsx.BackendTest do
  use ExUnit.Case, async: true

  alias Sheetshow.{Error, Log, Op, Store, Table, Workbook, Xlsx}
  alias Sheetshow.Log.Event
  alias Sheetshow.Xlsx.Zip

  setup do
    directory = Path.join(System.tmp_dir!(), "sheetshow-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(directory) end)
    %{path: Path.join(directory, "costs.xlsx"), directory: directory}
  end

  defp blank(path), do: Workbook.xlsx(path, create: true)

  defp written(path, cells, opts \\ []) do
    workbook = blank(path)
    {:ok, workbook} = Sheetshow.connect(workbook)
    existing = Keyword.get(opts, :existing_sheets, Map.keys(workbook.sheets))

    {:ok, workbook} =
      cells |> Sheetshow.plan!(existing_sheets: existing) |> Sheetshow.run(workbook)

    workbook
  end

  defp costs do
    Sheetshow.stack([
      Sheetshow.row(["Item", "Cost"], style: %{bold: true}),
      Sheetshow.rows([["Rent", 1000], ["Food", 400]])
    ])
    |> Sheetshow.put_sheet("Costs")
  end

  describe "a workbook that is not there yet" do
    test "is refused unless you said you meant it", %{path: path} do
      assert {:error, %Error{reason: :not_found} = error} = Sheetshow.connect(Workbook.xlsx(path))
      assert Exception.message(error) =~ "create: true"
    end

    test "is an empty workbook when you did", %{path: path} do
      assert {:ok, workbook} = Sheetshow.connect(blank(path))
      assert Map.keys(workbook.sheets) == ["Sheet1"]
    end

    test "and nothing is written until a plan is run", %{path: path} do
      {:ok, _workbook} = Sheetshow.connect(blank(path))
      refute File.exists?(path)
    end
  end

  describe "running a plan against a file" do
    test "writes it, and the workbook comes back knowing the sheets", %{path: path} do
      workbook = written(path, costs())

      assert File.exists?(path)
      assert Enum.sort(Map.keys(workbook.sheets)) == ["Costs", "Sheet1"]
    end

    test "and what went in comes back out", %{path: path} do
      workbook = written(path, costs())

      assert {:ok, rows} = Sheetshow.read_rows("Costs", workbook)
      assert rows == [["Item", "Cost"], ["Rent", 1000], ["Food", 400]]
    end

    test "cells keep their styles", %{path: path} do
      workbook = written(path, costs())

      assert {:ok, [cell | _]} = Sheetshow.read_cells("Costs!A1:B1", workbook)
      assert cell.style == %{bold: true}
    end

    test "an append lands after the last row", %{path: path} do
      workbook = written(path, costs())
      row = Sheetshow.row(["Bus", 50], sheet: "Costs")

      assert {:ok, workbook} = Sheetshow.run([Op.AppendRows.new(row)], workbook)
      assert {:ok, rows} = Sheetshow.read_rows("Costs", workbook)
      assert List.last(rows) == ["Bus", 50]
    end

    test "a sheet can be taken away", %{path: path} do
      workbook = written(path, costs())

      assert {:ok, workbook} = Sheetshow.run([Op.DeleteSheet.new("Sheet1")], workbook)
      assert Map.keys(workbook.sheets) == ["Costs"]

      {:ok, package} = Xlsx.open(File.read!(path))
      assert Xlsx.titles(package) == ["Costs"]
    end

    test "an empty plan asks the file nothing", %{path: path} do
      workbook = written(path, costs())
      before = File.stat!(path)

      assert {:ok, ^workbook} = Sheetshow.run([], workbook)
      assert File.stat!(path).mtime == before.mtime
    end

    test "a plan that fails leaves the file as it was", %{path: path} do
      workbook = written(path, costs())
      before = File.read!(path)

      put = Op.PutCells.new(Sheetshow.row([1], sheet: "nope"))

      assert {:error, %Error{reason: :unknown_sheet}} = Sheetshow.run([put], workbook)
      assert File.read!(path) == before
    end

    test "dimensions are kept", %{path: path} do
      cells =
        Sheetshow.row(["wide"], sheet: "Costs", style: %{col_width: 200, row_height: 40})

      written(path, cells)
      {:ok, package} = Xlsx.open(File.read!(path))
      {:ok, sheet} = Xlsx.sheet(package, "Costs")

      assert_in_delta sheet.col_widths[0], 200, 1
      assert sheet.row_heights == %{0 => 40}
    end
  end

  describe "only what the plan names is read" do
    setup %{path: path} do
      # Three sheets, then one of them damaged past parsing. Anything that
      # still works did not read it.
      cells =
        Sheetshow.put_sheet(Sheetshow.row([1]), "one") ++
          Sheetshow.put_sheet(Sheetshow.row([2]), "two") ++
          Sheetshow.put_sheet(Sheetshow.row([3]), "three")

      workbook = written(path, cells)

      {:ok, package} = Xlsx.open(File.read!(path))
      %{part: part} = Enum.find(package.book.sheets, &(&1.title == "three"))
      {:ok, damaged} = package.entries |> Zip.put(part, "<not xml at all") |> Zip.write()
      File.write!(path, damaged)

      %{workbook: workbook}
    end

    test "a plan touching one sheet does not parse the others", %{workbook: workbook} do
      row = Sheetshow.row(["x"], sheet: "one")

      assert {:ok, _} = Sheetshow.run([Op.PutCells.new(row)], workbook)
    end

    test "nor does reading one", %{workbook: workbook} do
      assert {:ok, [[1]]} = Sheetshow.read_rows("one", workbook)
    end

    test "and a plan that does name it fails on it", %{workbook: workbook} do
      row = Sheetshow.row(["x"], sheet: "three")

      assert {:error, %Error{reason: :invalid_xlsx}} =
               Sheetshow.run([Op.PutCells.new(row)], workbook)
    end

    test "several ranges at once cost one read of the file", %{workbook: workbook} do
      assert {:ok, [[[1]], [[2]]]} = Sheetshow.read_rows(["one", "two"], workbook)
    end
  end

  describe "a write that would clobber somebody" do
    test "is refused when the file has changed since it was read", %{path: path} do
      written(path, costs())

      # Another writer, between this workbook's read and its write. The backend
      # reads the file inside run/2, so the change has to land during that,
      # which is what a second workbook over the same file amounts to here.
      {:ok, package} = Xlsx.open(File.read!(path))
      {:ok, package} = Xlsx.add_sheet(package, "theirs")
      {:ok, bytes} = Xlsx.encode(package)

      store = Store.local(path)
      {:ok, {_before, version}} = Store.read(store)
      File.write!(path, bytes)

      assert {:error, %Error{reason: :conflict}} = Store.write(store, "ours", version)
      assert {:ok, again} = Xlsx.open(File.read!(path))
      assert "theirs" in Xlsx.titles(again)
    end

    test "and the backend says it cannot promise otherwise", %{path: path} do
      refute Sheetshow.Backend.supports?(blank(path), :conditional_write)
    end
  end

  describe "the database models, over a file" do
    test "a table can be created, read, updated and read again", %{path: path} do
      {:ok, workbook} = Sheetshow.connect(blank(path))
      table = Table.new("costs", item: :string, cost: :float)

      inserts = [
        Table.insert(%{item: "Rent", cost: 1000.0}),
        Table.insert(%{item: "Food", cost: 400.0})
      ]

      plan = Table.create(table) ++ Table.plan!(inserts, Table.empty(table))
      assert {:ok, workbook} = Sheetshow.run(plan, workbook)

      assert {:ok, snapshot} = Table.read(table, workbook)
      assert Enum.map(Table.live(snapshot), & &1.record.item) == ["Rent", "Food"]

      [first | _] = Table.live(snapshot)
      change = Table.update(first.id, %{cost: 1100.0})
      assert {:ok, workbook} = Sheetshow.run(Table.plan!([change], snapshot), workbook)

      assert {:ok, snapshot} = Table.read(table, workbook)
      assert Enum.map(Table.live(snapshot), & &1.record.cost) == [1100.0, 400.0]
    end

    test "a log can be appended to and folded", %{path: path} do
      {:ok, workbook} = Sheetshow.connect(blank(path))
      log = Log.new("log", item: :string, cost: :float)

      events = [Event.new(%{item: "Bus", cost: 50.0}), Event.new(%{item: "Taxi", cost: 90.0})]
      plan = Log.create(log) ++ Log.plan!(events, log)

      assert {:ok, workbook} = Sheetshow.run(plan, workbook)
      assert {:ok, read} = Log.read(log, workbook)
      assert Enum.map(Log.fold(read), & &1.record.item) == ["Bus", "Taxi"]
    end

    test "but a log over a file has no server to resolve an append", %{path: path} do
      # The property Log rests on at Google, which a file cannot give: two
      # writers appending to the same file can lose each other's rows.
      refute Sheetshow.Backend.supports?(blank(path), :server_side_append)
    end
  end

  describe "reading" do
    test "needs a sheet, here as everywhere", %{path: path} do
      workbook = written(path, costs())

      assert {:error, %Error{reason: :invalid_range}} = Sheetshow.read_rows("A1:B2", workbook)
    end

    test "a sheet the workbook does not have", %{path: path} do
      workbook = written(path, costs())

      assert {:error, %Error{reason: :unknown_sheet}} = Sheetshow.read_rows("nope", workbook)
    end

    test "an empty list of ranges asks nothing", %{path: path} do
      assert {:ok, []} = Sheetshow.read_rows([], written(path, costs()))
    end
  end

  describe "a file that is not a workbook" do
    test "says so rather than half-reading it", %{path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "this is not a spreadsheet")

      assert {:error, %Error{reason: :invalid_zip}} = Sheetshow.connect(Workbook.xlsx(path))
    end
  end

  # What Excel leaves in a file that a writer here has to carry through.
  describe "a file Excel wrote" do
    # A column filled down: the first cell holds the formula, the rest point at
    # it. Made by rewriting one part of a file this library wrote, since
    # neither openpyxl nor LibreOffice shares formulas and Excel is not here.
    defp with_shared_formulas(path) do
      cells =
        Sheetshow.rows([[1, {:formula, "=A1*2"}], [2, nil], [3, nil]], sheet: "Costs")
        |> Enum.reject(&is_nil(&1.value))

      written(path, cells)

      {:ok, package} = Xlsx.open(File.read!(path))
      %{part: part} = Enum.find(package.book.sheets, &(&1.title == "Costs"))
      {:ok, xml} = Zip.fetch(package.entries, part)

      xml =
        xml
        |> String.replace("<f>A1*2</f>", ~s(<f t="shared" ref="B1:B3" si="0">A1*2</f>))
        |> String.replace(
          "<c r=\"A2\"><v>2</v></c>",
          ~s(<c r="A2"><v>2</v></c><c r="B2"><f t="shared" si="0"/><v>4</v></c>)
        )
        |> String.replace(
          "<c r=\"A3\"><v>3</v></c>",
          ~s(<c r="A3"><v>3</v></c><c r="B3"><f t="shared" si="0"/><v>6</v></c>)
        )

      assert xml =~ ~s(<f t="shared" si="0"/>), "the fixture did not take"
      {:ok, bin} = package.entries |> Zip.put(part, xml) |> Zip.write()
      File.write!(path, bin)
      Workbook.xlsx(path)
    end

    test "filled-down formulas read as the formula each cell holds", %{path: path} do
      workbook = with_shared_formulas(path)

      assert {:ok, cells} = Sheetshow.read_cells("Costs!B1:B3", workbook)

      assert Enum.map(cells, & &1.value) == [
               {:formula, "=A1*2"},
               {:formula, "=A2*2"},
               {:formula, "=A3*2"}
             ]
    end

    test "and a write to the sheet leaves them as formulas of their own", %{path: path} do
      workbook = with_shared_formulas(path)
      {:ok, workbook} = Sheetshow.connect(workbook)

      {:ok, workbook} =
        [Sheetshow.Cell.new("Costs!D1", "touched")]
        |> Sheetshow.plan!()
        |> Sheetshow.run(workbook)

      {:ok, package} = Xlsx.open(File.read!(path))
      %{part: part} = Enum.find(package.book.sheets, &(&1.title == "Costs"))
      {:ok, xml} = Zip.fetch(package.entries, part)

      assert xml =~ "<f>A2*2</f>"
      assert xml =~ "<f>A3*2</f>"
      refute xml =~ "<f></f>"
      refute xml =~ "shared"

      assert {:ok, [[{:formula, "=A1*2"}], [{:formula, "=A2*2"}], [{:formula, "=A3*2"}]]} =
               Sheetshow.read_rows("Costs!B1:B3", workbook)
    end

    # Conditional formatting keeps its fonts and fills under <dxfs>, beside the
    # lists a cell indexes into, and they must not be counted with them: a
    # style minted afterwards would point past the end of <fonts>.
    test "conditional formatting does not push a new style past the font list", %{path: path} do
      written(path, costs())

      {:ok, package} = Xlsx.open(File.read!(path))
      {:ok, styles} = Zip.fetch(package.entries, package.book.styles)

      dxfs =
        ~s(<dxfs count="1"><dxf><font><b/><color rgb="FFFF0000"/></font>) <>
          ~s(<fill><patternFill patternType="solid"><fgColor rgb="FFFFFF00"/></patternFill></fill></dxf></dxfs>)

      styles = String.replace(styles, "</cellStyles>", "</cellStyles>" <> dxfs)
      {:ok, bin} = package.entries |> Zip.put(package.book.styles, styles) |> Zip.write()
      File.write!(path, bin)

      {:ok, workbook} = Sheetshow.connect(Workbook.xlsx(path))
      cell = Sheetshow.Cell.new("Costs!A5", "x", %{italic: true, background: "#00FF00"})
      {:ok, workbook} = [cell] |> Sheetshow.plan!() |> Sheetshow.run(workbook)

      {:ok, package} = Xlsx.open(File.read!(path))
      {:ok, styles} = Zip.fetch(package.entries, package.book.styles)
      [fonts] = Regex.run(~r{<fonts.*?</fonts>}s, styles)
      [fills] = Regex.run(~r{<fills.*?</fills>}s, styles)
      [xf] = Regex.run(~r{<xf [^>]*applyFill="1"[^>]*>}, styles)
      [_, font_id] = Regex.run(~r/fontId="(\d+)"/, xf)
      [_, fill_id] = Regex.run(~r/fillId="(\d+)"/, xf)

      assert String.to_integer(font_id) < length(Regex.scan(~r/<font>/, fonts))
      assert String.to_integer(fill_id) < length(Regex.scan(~r/<fill>/, fills))

      {:ok, [read]} = Sheetshow.read_cells("Costs!A5", workbook)
      assert read.style == %{italic: true, background: "#00FF00"}
    end
  end
end
