if Sheetshow.Integration.configured?() do
  defmodule Sheetshow.Integration.ValuesTest do
    use ExUnit.Case, async: true

    @moduletag :integration
    @moduletag timeout: 120_000

    import Sheetshow.Integration

    alias Sheetshow.{Fixtures, Memory}

    setup_all do: connect()

    test "connect finds the spreadsheet and its tabs", %{workbook: workbook} do
      assert map_size(workbook.sheets) > 0
      assert Enum.all?(workbook.sheets, fn {title, id} -> is_binary(title) and is_integer(id) end)
    end

    test "every kind of value reads back as what was written", %{workbook: workbook} do
      title = tab()

      values = ["text", 42, 2.5, true, ~D[2026-09-12], ~N[2026-09-12 08:30:00], ~T[08:30:00]]
      workbook = write(workbook, Sheetshow.row(values, sheet: title))

      {:ok, answer} = Sheetshow.Google.Backend.get(quoted(title), workbook)
      Fixtures.record("values", answer, spreadsheet_id())

      assert answer |> Sheetshow.Google.decode() |> Enum.map(& &1.value) == values
    end

    test "the memory backend and Google agree on what a plan writes", %{workbook: workbook} do
      title = tab()

      cells =
        Sheetshow.stack([
          Sheetshow.row(["Item", "Cost"], style: %{bold: true}),
          Sheetshow.records(
            [%{item: "Rent", cost: 1000}, %{item: "Food", cost: 400}],
            [:item, :cost]
          )
        ])
        |> Sheetshow.put_sheet(title)

      # One plan, carried out in both places: the `AddSheet` that makes the tab
      # included, which is the part `Memory` used to be handed for free.
      existing = Map.keys(workbook.sheets)
      plan = Sheetshow.plan!(cells, existing_sheets: existing)

      memory = Memory.run!(plan, Memory.new(existing))
      remembered = quoted(title) |> Memory.read!(memory) |> Sheetshow.to_rows()

      {:ok, workbook} = Sheetshow.run(plan, workbook)

      assert {:ok, read} = Sheetshow.read_cells(quoted(title), workbook)
      assert Sheetshow.to_rows(read) == remembered
    end
  end
end
