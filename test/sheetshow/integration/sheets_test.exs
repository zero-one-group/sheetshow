if Sheetshow.Integration.configured?() do
  defmodule Sheetshow.Integration.SheetsTest do
    use ExUnit.Case, async: true

    @moduletag :integration
    @moduletag timeout: 120_000

    import Sheetshow.Integration

    alias Sheetshow.Op

    setup_all do: connect()

    test "appending lands below the data, and deleting rows closes the gap", %{workbook: workbook} do
      title = tab()

      workbook = write(workbook, Sheetshow.rows([["a"], ["b"]], sheet: title))

      {:ok, workbook} =
        Sheetshow.run([Op.AppendRows.new(Sheetshow.row(["c"]), title)], workbook)

      assert {:ok, read} = Sheetshow.read_cells(quoted(title), workbook)
      assert Sheetshow.to_rows(read) == [["a"], ["b"], ["c"]]

      {:ok, workbook} = Sheetshow.run([Op.DeleteRows.new(title, 1..1)], workbook)

      assert {:ok, read} = Sheetshow.read_cells(quoted(title), workbook)
      assert Sheetshow.to_rows(read) == [["a"], ["c"]]
    end

    # The one test that still spends a request on each: adding and deleting a
    # tab is what it is about.
    test "a sheet can be added and taken away again", %{workbook: workbook} do
      title = tab()

      before = workbook.sheets
      {:ok, workbook} = Sheetshow.run([Op.AddSheet.new(title)], workbook)

      # Google honoured the id we asked for, which is what lets a plan write to
      # a tab it is creating in the same batch.
      assert workbook.sheets[title] == Sheetshow.Google.sheet_id(title, before)

      {:ok, workbook} = Sheetshow.run([Op.DeleteSheet.new(title)], workbook)
      refute Map.has_key?(workbook.sheets, title)

      {:ok, workbook} = Sheetshow.fetch_sheets(workbook)
      refute Map.has_key?(workbook.sheets, title)
    end

    test "an error from Google says what Google said", %{workbook: workbook} do
      assert {:error, %Sheetshow.Error{reason: :http} = error} =
               Sheetshow.read_cells("'no such tab'!A1", workbook)

      assert error.details.status in [400, 404]
      assert is_binary(error.message)
    end
  end
end
