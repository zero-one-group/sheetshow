defmodule Sheetshow.MemoryTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.Memory

  alias Sheetshow.{Cell, Error, Memory}
  alias Sheetshow.Op.{AddSheet, AppendRows, DeleteRows, DeleteSheet, PutCells, SetDimensions}

  # A sheet called Costs, written one run of cells per group.
  defp costs(groups \\ []) do
    Memory.run!(Enum.map(groups, &PutCells.new(&1, "Costs")), Memory.new(["Costs"]))
  end

  # Rows of values as one run of cells each, which is what PutCells takes.
  defp runs(rows) do
    for {values, i} <- Enum.with_index(rows), do: Sheetshow.row(values, row: i)
  end

  defp table(memory) do
    case Memory.read!("Costs", memory) do
      [] -> []
      cells -> Sheetshow.to_rows(cells)
    end
  end

  describe "sheets" do
    test "AddSheet adds an empty one" do
      {:ok, memory} = Memory.run(AddSheet.new("Costs"), Memory.new())

      assert Memory.titles(memory) == ["Costs"]
      assert Memory.read!("Costs", memory) == []
    end

    test "adding a sheet twice fails, as it does at Google" do
      assert {:error, %Error{reason: :duplicate_sheet, details: %{sheet: "Costs"}}} =
               Memory.run(AddSheet.new("Costs"), Memory.new(["Costs"]))
    end

    test "writing to a sheet that is not there fails, so a plan cannot forget AddSheet" do
      plan = [PutCells.new(Sheetshow.row([1]), "Costs")]

      assert {:error, %Error{reason: :unknown_sheet, details: details}} =
               Memory.run(plan, Memory.new(["log"]))

      assert details == %{sheet: "Costs", sheets: ["log"]}

      assert {:ok, _} = Memory.run([AddSheet.new("Costs") | plan], Memory.new(["log"]))
    end

    test "DeleteSheet takes the sheet and everything on it" do
      memory = costs([Sheetshow.row([1])])

      assert {:ok, memory} = Memory.run(DeleteSheet.new("Costs"), memory)
      assert Memory.titles(memory) == []
      assert {:error, %Error{reason: :unknown_sheet}} = Memory.read("Costs", memory)
    end

    test "every op checks the sheet is there" do
      ops = [
        AppendRows.new(Sheetshow.row([1]), "Costs"),
        DeleteSheet.new("Costs"),
        DeleteRows.new("Costs", 0..0),
        PutCells.new(Sheetshow.row([1]), "Costs"),
        SetDimensions.new("Costs", :cols, 0..0, 100)
      ]

      for op <- ops do
        assert {:error, %Error{reason: :unknown_sheet}} = Memory.run(op, Memory.new())
      end
    end
  end

  describe "run" do
    test "takes one op or a plan, and leaves nothing half-done" do
      memory = Memory.new()
      one = Memory.run!(AddSheet.new("Costs"), memory)
      assert Memory.run!([AddSheet.new("Costs")], memory) == one

      plan = [AddSheet.new("log"), PutCells.new(Sheetshow.row([1]), "nowhere")]
      assert {:error, %Error{reason: :unknown_sheet}} = Memory.run(plan, one)
      assert Memory.titles(one) == ["Costs"]
    end

    test "later ops see what earlier ones did" do
      plan = [
        AddSheet.new("Costs"),
        PutCells.new(Sheetshow.row(["Rent", 1000], sheet: "Costs")),
        AppendRows.new(Sheetshow.row(["Food", 400]), "Costs")
      ]

      assert Memory.run!(plan, Memory.new()) |> table() == [["Rent", 1000], ["Food", 400]]
    end

    test "run! raises the error run returns" do
      assert_raise Error, fn -> Memory.run!(AddSheet.new("Costs"), Memory.new(["Costs"])) end
    end
  end

  describe "PutCells" do
    test "writes cells with the op's sheet on them" do
      memory = costs([Sheetshow.row([1, 2])])

      assert [%Cell{coord: coord, value: 1} | _] = Memory.read!("Costs", memory)
      assert coord.sheet == "Costs"
    end

    test "a later write to the same cell wins" do
      memory =
        costs([
          Sheetshow.row([1, 2]),
          Sheetshow.row([9], col: 1)
        ])

      assert table(memory) == [[1, 9]]
    end

    test "a cell with nothing in it clears the cell, one with a style does not" do
      memory = costs([Sheetshow.row([1, 2, 3])])

      cleared = Memory.run!(PutCells.new([Cell.new("B1")], "Costs"), memory)
      assert table(cleared) == [[1, nil, 3]]

      kept = Memory.run!(PutCells.new([Cell.new("B1", nil, %{bold: true})], "Costs"), memory)
      assert [%Cell{style: %{bold: true}}] = Memory.read!("Costs!B1", kept)
    end

    test "writing a run leaves its neighbours alone" do
      memory =
        costs([
          Sheetshow.row([1, 2, 3]),
          Sheetshow.row([9], col: 2)
        ])

      assert table(memory) == [[1, 2, 9]]
    end
  end

  describe "AppendRows" do
    test "starts at row 0 on an empty sheet" do
      memory = Memory.run!(AppendRows.new(Sheetshow.row([1]), "Costs"), costs())
      assert Memory.read!("Costs", memory) |> hd() |> Map.fetch!(:coord) |> Map.fetch!(:row) == 0
    end

    test "lands below the last row with data, wherever the data is" do
      memory =
        costs([Sheetshow.row(["x"], row: 4, col: 3)])
        |> then(&Memory.run!(AppendRows.new(Sheetshow.row(["y"]), "Costs"), &1))

      assert Memory.read!("Costs!A6", memory) |> Enum.map(& &1.value) == ["y"]
    end

    test "a gap at the top of the payload leaves blank rows" do
      cells = Sheetshow.row(["y"], row: 2)
      memory = Memory.run!(AppendRows.new(cells, "Costs"), costs([Sheetshow.row(["x"])]))

      assert table(memory) == [["x"], [nil], [nil], ["y"]]
    end

    test "appending nothing changes nothing" do
      memory = costs([Sheetshow.row(["x"])])
      assert Memory.run!(AppendRows.new([], "Costs"), memory) == memory
    end
  end

  describe "DeleteRows" do
    test "removes the rows and moves the ones below up" do
      memory = costs(runs([["a"], ["b"], ["c"], ["d"]]))

      assert Memory.run!(DeleteRows.new("Costs", 1..2), memory) |> table() == [["a"], ["d"]]
    end

    test "takes the row heights with it" do
      memory =
        Memory.run!(
          [
            SetDimensions.new("Costs", :rows, 0..0, 20),
            SetDimensions.new("Costs", :rows, 3..3, 60),
            DeleteRows.new("Costs", 1..2)
          ],
          costs()
        )

      assert Memory.dimensions!("Costs", memory).row_heights == %{0 => 20, 1 => 60}
    end

    test "deleting rows with nothing in them is fine: a memory has no grid" do
      memory = costs([Sheetshow.row(["a"])])
      assert Memory.run!(DeleteRows.new("Costs", 100..200), memory) |> table() == [["a"]]
    end
  end

  describe "SetDimensions" do
    test "sets a size per index, on the axis it names" do
      memory =
        Memory.run!(
          [
            SetDimensions.new("Costs", :cols, 0..1, 180),
            SetDimensions.new("Costs", :cols, 1..1, 60),
            SetDimensions.new("Costs", :rows, 2..2, 40)
          ],
          costs()
        )

      assert Memory.dimensions!("Costs", memory) == %{
               col_widths: %{0 => 180, 1 => 60},
               row_heights: %{2 => 40}
             }
    end

    test "dimensions! raises for a sheet that is not there" do
      assert_raise Error, fn -> Memory.dimensions!("log", Memory.new()) end
    end
  end

  describe "read" do
    setup do
      {:ok, memory: costs(runs([[1, 2], [3, 4]]))}
    end

    test "gives back the cells inside the range, in reading order", %{memory: memory} do
      assert Memory.read!("Costs!A1:B2", memory) |> Enum.map(& &1.value) == [1, 2, 3, 4]
      assert Memory.read!("Costs!B1:B2", memory) |> Enum.map(& &1.value) == [2, 4]
      assert Memory.read!("Costs!A3:B9", memory) == []
    end

    test "takes a range as well as A1", %{memory: memory} do
      range = Sheetshow.Range.new("Costs", 0..0, 0..1)
      assert Memory.read!(range, memory) |> Enum.map(& &1.value) == [1, 2]
    end

    test "an open range reads what is there", %{memory: memory} do
      assert Memory.read!("Costs!A2:B", memory) |> Enum.map(& &1.value) == [3, 4]
    end

    test "a range needs a sheet, and one that is there", %{memory: memory} do
      assert {:error, %Error{reason: :invalid_range}} = Memory.read("A1:B2", memory)
      assert {:error, %Error{reason: :unknown_sheet}} = Memory.read("log!A1", memory)
      assert {:error, %Error{reason: :invalid_a1}} = Memory.read("A0", memory)
      assert_raise Error, fn -> Memory.read!("log!A1", memory) end
    end
  end
end
