defmodule Sheetshow.Contract.WebDAVTest do
  use ExUnit.Case, async: true

  # The backend contract over an `.xlsx` on a WebDAV server, with `Sheetshow.FakeDAV`
  # which keeps the file and its entity tag and refuses a stale `If-Match` the
  # way Nextcloud does. Every request goes over HTTP on localhost, so this is
  # the store, the codec and the conditional write together.

  import Sheetshow.BackendContract

  alias Sheetshow.{Backend, FakeDAV, Store, Workbook}

  setup do
    store = Store.webdav(FakeDAV.start(), username: "user", password: "pw")
    {:ok, workbook} = store |> Workbook.xlsx(create: true) |> Sheetshow.connect()
    %{workbook: workbook, sheet: "tab #{System.unique_integer([:positive])}"}
  end

  test "promises the conditional write a local file cannot", %{workbook: w} do
    assert Backend.supports?(w, :conditional_write)
  end

  test("answers for every capability", %{workbook: w}, do: answers_for_every_capability(w))

  test("learns the sheets it makes", %{workbook: w, sheet: s},
    do: learns_the_sheets_it_makes(w, s)
  )

  test("writes land where the cells say", %{workbook: w, sheet: s},
    do: writes_land_where_the_cells_say(w, s)
  )

  test("every kind of value round-trips", %{workbook: w, sheet: s},
    do: every_kind_of_value_round_trips(w, s)
  )

  test("an empty range is nothing", %{workbook: w, sheet: s}, do: an_empty_range_is_nothing(w, s))

  test("a write leaves its neighbours alone", %{workbook: w, sheet: s},
    do: a_write_leaves_its_neighbours_alone(w, s)
  )

  test("an append lands below the data", %{workbook: w, sheet: s},
    do: an_append_lands_below_the_data(w, s)
  )

  test("deleting rows closes the gap", %{workbook: w, sheet: s},
    do: deleting_rows_closes_the_gap(w, s)
  )

  test("a style survives when promised", %{workbook: w, sheet: s},
    do: a_style_survives_when_promised(w, s)
  )

  test("refuses what it cannot do", %{workbook: w}, do: refuses_what_it_cannot_do(w))
  test("a sheet comes and goes", %{workbook: w, sheet: s}, do: a_sheet_comes_and_goes(w, s))
  test("a log appends and folds", %{workbook: w, sheet: s}, do: a_log_appends_and_folds(w, s))
  test("a table cycles", %{workbook: w, sheet: s}, do: a_table_cycles(w, s))
end
