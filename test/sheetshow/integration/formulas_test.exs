if Sheetshow.Integration.configured?() do
  defmodule Sheetshow.Integration.FormulasTest do
    use ExUnit.Case, async: true

    @moduletag :integration
    @moduletag timeout: 120_000

    import Sheetshow.Integration

    alias Sheetshow.CellError

    setup_all do: connect()

    test "a formula reads back as a formula, with what it came to alongside", %{
      workbook: workbook
    } do
      title = tab()
      values = [6, 7, {:formula, "=A1*B1"}]

      workbook = write(workbook, Sheetshow.row(values, sheet: title))

      assert {:ok, read} = Sheetshow.read_cells(quoted(title), workbook)
      assert Enum.map(read, & &1.value) == values

      product = List.last(read)
      assert product.meta.effective == 42
      assert product.meta.formatted == "42"
    end

    test "a formula that cannot work out is a CellError, never a value", %{workbook: workbook} do
      title = tab()

      workbook = write(workbook, Sheetshow.row([{:formula, "=1/0"}], sheet: title))

      assert {:ok, [cell]} = Sheetshow.read_cells(quoted(title), workbook)
      assert cell.value == {:formula, "=1/0"}
      assert %CellError{type: :divide_by_zero} = cell.meta.effective
      assert cell.meta.formatted == "#DIV/0!"
    end
  end
end
