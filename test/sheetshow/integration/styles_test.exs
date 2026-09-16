if Sheetshow.Integration.configured?() do
  defmodule Sheetshow.Integration.StylesTest do
    use ExUnit.Case, async: true

    @moduletag :integration
    @moduletag timeout: 120_000

    import Sheetshow.Integration

    setup_all do: connect()

    test "a style survives the round trip", %{workbook: workbook} do
      title = tab()

      style = %{
        bold: true,
        italic: true,
        font_size: 14,
        color: "#FF8800",
        background: "#FFF2CC",
        horizontal: :center,
        number_format: "0.00%"
      }

      workbook = write(workbook, Sheetshow.row([0.22], sheet: title, style: style))

      assert {:ok, [cell]} = Sheetshow.read_cells(quoted(title), workbook)
      assert cell.style == style
      assert cell.meta.formatted == "22.00%"
    end

    test "a column width is set on the sheet, not on a cell", %{workbook: workbook} do
      title = tab()

      workbook =
        write(workbook, Sheetshow.row(["wide"], sheet: title, style: %{col_width: 240}))

      assert {:ok, [cell]} = Sheetshow.read_cells(quoted(title), workbook)
      assert cell.value == "wide"
      refute Map.has_key?(cell.style, :col_width)
    end
  end
end
