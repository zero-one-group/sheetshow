if Sheetshow.Integration.configured?() do
  defmodule Sheetshow.Integration.ContractTest do
    use ExUnit.Case, async: true

    @moduletag :integration
    @moduletag timeout: 120_000

    # The backend contract against the real Sheets API: only the checks the
    # other integration files do not already make, because each one here is a
    # write against the quota. Four writes and five reads.

    import Sheetshow.BackendContract
    import Sheetshow.Integration, only: [connect: 0, tab: 0]

    setup_all do: connect()

    test("answers for every capability", %{workbook: w}, do: answers_for_every_capability(w))

    test("writes land where the cells say", %{workbook: w},
      do: writes_land_where_the_cells_say(w, tab())
    )

    test("an empty range is nothing", %{workbook: w}, do: an_empty_range_is_nothing(w, tab()))

    test("a write leaves its neighbours alone", %{workbook: w},
      do: a_write_leaves_its_neighbours_alone(w, tab())
    )

    test("refuses what it cannot do", %{workbook: w}, do: refuses_what_it_cannot_do(w))
  end
end
