if Sheetshow.Integration.configured?() do
  defmodule Sheetshow.Integration.GuidesTest do
    use ExUnit.Case, async: true

    @moduletag :integration
    @moduletag timeout: 300_000

    # The Google quick start, run against the real spreadsheet: every block on
    # the page except the one that connects, which the integration workbook
    # stands in for. The page makes four tabs with fixed names and deletes them
    # at the end; a run that died halfway leaves them behind, so they are swept
    # first. Nine writes and ten reads.

    import Sheetshow.Integration, only: [connect: 0]

    alias Sheetshow.{Guides, Op, Workbook}

    @guide "guides/quick-start-google.md"
    @tabs ["Costs", "expenses", "expenses log", "expenses now"]

    setup_all do: connect()

    test "the Google quick start runs as written, against the spreadsheet", %{workbook: workbook} do
      {:ok, workbook} = Sheetshow.fetch_sheets(workbook)
      leftovers = Enum.filter(Workbook.titles(workbook), &(&1 in @tabs))
      {:ok, workbook} = Sheetshow.run(Enum.map(leftovers, &Op.DeleteSheet.new/1), workbook)

      binding = Guides.run(@guide, workbook: workbook)

      assert Enum.filter(Workbook.titles(binding[:workbook]), &(&1 in @tabs)) == []
    end
  end
end
