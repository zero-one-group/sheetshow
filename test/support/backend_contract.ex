defmodule Sheetshow.BackendContract do
  @moduledoc false
  # What every backend has to agree on, written once and run against each of
  # them: the in-memory one, an `.xlsx` on disk, an `.xlsx` on a WebDAV server,
  # and, for the checks that are not already integration tests, Google.
  #
  # No case template and no macro: a test module `import`s this and writes one
  # line per check, handing over a connected workbook and a tab name nothing
  # else is using. Each check returns the workbook it leaves behind, so a
  # module can chain them if it wants to. The tab is `sheet` in every message
  # so a failure says which backend and which tab.
  #
  # A backend may not promise everything, and `Sheetshow.Backend.capabilities/1`
  # says what it does, so the checks that need a promise ask for it first.

  import ExUnit.Assertions

  alias Sheetshow.{Backend, Error, Log, Op, Table, Workbook}
  alias Sheetshow.Log.Event

  @doc "Every capability the behaviour knows has a yes or a no."
  def answers_for_every_capability(%Workbook{} = workbook) do
    capabilities = Backend.capabilities(workbook)

    for capability <- Backend.known() do
      assert is_boolean(capabilities[capability]), "#{capability} has no answer"
    end

    workbook
  end

  @doc "A plan that adds a tab leaves the workbook knowing it, and so does connecting again."
  def learns_the_sheets_it_makes(%Workbook{} = workbook, sheet) do
    {:ok, workbook} = Sheetshow.run([Op.AddSheet.new(sheet)], workbook)
    assert sheet in Workbook.titles(workbook)

    {:ok, reconnected} = Sheetshow.connect(workbook)
    assert sheet in Workbook.titles(reconnected)

    reconnected
  end

  @doc "Cells land where the layout put them, and both reads give them back."
  def writes_land_where_the_cells_say(%Workbook{} = workbook, sheet) do
    cells =
      Sheetshow.stack([
        Sheetshow.row(["Item", "Cost"]),
        Sheetshow.records([%{item: "Rent", cost: 1000}, %{item: "Food", cost: 400}], [
          :item,
          :cost
        ])
      ])
      |> Sheetshow.put_sheet(sheet)

    workbook = write(workbook, cells)
    expected = [["Item", "Cost"], ["Rent", 1000], ["Food", 400]]

    {:ok, read} = Sheetshow.read_cells(sheet, workbook)
    assert Sheetshow.to_rows(read) == expected
    assert Enum.all?(read, &(&1.coord.sheet == sheet))

    assert {:ok, ^expected} = Sheetshow.read_rows(sheet, workbook)
    assert {:ok, [[1000], [400]]} = Sheetshow.read_rows("'#{sheet}'!B2:B3", workbook)

    workbook
  end

  @doc "Every kind of value comes back as the kind it went in as."
  def every_kind_of_value_round_trips(%Workbook{} = workbook, sheet) do
    values = ["text", 42, 2.5, true, ~D[2026-09-12], ~N[2026-09-12 08:30:00], ~T[08:30:00]]
    workbook = write(workbook, Sheetshow.row(values, sheet: sheet))

    {:ok, read} = Sheetshow.read_cells(sheet, workbook)
    assert Enum.map(read, & &1.value) == values

    workbook
  end

  @doc "A range with nothing in it is no cells and no rows, which `to_rows/1` takes."
  def an_empty_range_is_nothing(%Workbook{} = workbook, sheet) do
    workbook = write(workbook, Sheetshow.row([1], sheet: sheet))

    assert {:ok, []} = Sheetshow.read_cells("'#{sheet}'!D10:F12", workbook)
    assert {:ok, []} = Sheetshow.read_rows("'#{sheet}'!D10:F12", workbook)
    assert [] = Sheetshow.read_cells!("'#{sheet}'!D10:F12", workbook) |> Sheetshow.to_rows()

    workbook
  end

  @doc "Writing one cell leaves its neighbours as they were."
  def a_write_leaves_its_neighbours_alone(%Workbook{} = workbook, sheet) do
    workbook = write(workbook, Sheetshow.row(["a", "b", "c"], sheet: sheet))
    workbook = write(workbook, [Sheetshow.Cell.new("'#{sheet}'!B1", "B")])

    assert {:ok, [["a", "B", "c"]]} = Sheetshow.read_rows(sheet, workbook)

    workbook
  end

  @doc "An append lands below the last row with data."
  def an_append_lands_below_the_data(%Workbook{} = workbook, sheet) do
    workbook = write(workbook, Sheetshow.rows([["a", 1], ["b", 2]], sheet: sheet))

    {:ok, workbook} =
      Sheetshow.run([Op.AppendRows.new(Sheetshow.row(["c", 3]), sheet)], workbook)

    assert {:ok, [["a", 1], ["b", 2], ["c", 3]]} = Sheetshow.read_rows(sheet, workbook)

    workbook
  end

  @doc "Deleting rows moves the ones below up."
  def deleting_rows_closes_the_gap(%Workbook{} = workbook, sheet) do
    workbook = write(workbook, Sheetshow.rows([["a"], ["b"], ["c"]], sheet: sheet))
    {:ok, workbook} = Sheetshow.run([Op.DeleteRows.new(sheet, 1..1)], workbook)

    assert {:ok, [["a"], ["c"]]} = Sheetshow.read_rows(sheet, workbook)

    workbook
  end

  @doc "A style comes back when the backend keeps styles."
  def a_style_survives_when_promised(%Workbook{} = workbook, sheet) do
    if Backend.supports?(workbook, :styles) do
      workbook = write(workbook, Sheetshow.row(["bold"], sheet: sheet, style: %{bold: true}))

      {:ok, [cell]} = Sheetshow.read_cells(sheet, workbook)
      assert cell.style[:bold] == true

      workbook
    else
      workbook
    end
  end

  @doc "A plan for a sheet that is not there is refused, and an empty plan asks for nothing."
  def refuses_what_it_cannot_do(%Workbook{} = workbook) do
    plan = Sheetshow.plan!(Sheetshow.row([1], sheet: "no such sheet #{System.unique_integer()}"))
    assert {:error, %Error{reason: :unknown_sheet}} = Sheetshow.run(plan, workbook)

    assert {:ok, ^workbook} = Sheetshow.run([], workbook)

    workbook
  end

  @doc "A sheet can be added once, and taken away."
  def a_sheet_comes_and_goes(%Workbook{} = workbook, sheet) do
    {:ok, workbook} = Sheetshow.run([Op.AddSheet.new(sheet)], workbook)

    assert {:error, %Error{reason: :duplicate_sheet}} =
             Sheetshow.run([Op.AddSheet.new(sheet)], workbook)

    {:ok, workbook} = Sheetshow.run([Op.DeleteSheet.new(sheet)], workbook)
    refute sheet in Workbook.titles(workbook)

    workbook
  end

  @doc "A log is created, appended to, folded and read from a cursor."
  def a_log_appends_and_folds(%Workbook{} = workbook, sheet) do
    log = Log.new(sheet, item: :string, cost: :decimal)
    rent = Event.new(%{item: "Rent", cost: "1000.00"}, id: "a")
    food = Event.new(%{item: "Food", cost: "400.00"}, id: "b")

    {:ok, workbook} = Sheetshow.run(Log.create(log) ++ Log.plan!([rent, food], log), workbook)
    {:ok, events} = Log.read(log, workbook)
    assert Enum.map(events, &{&1.id, &1.row}) == [{"a", 1}, {"b", 2}]

    later = [Event.put(rent, %{cost: "1100.00"}), Event.delete(food)]
    {:ok, workbook} = Sheetshow.run(Log.plan!(later, log), workbook)

    {:ok, new} = Log.read(log, workbook, after: List.last(events))
    assert Enum.map(new, &{&1.id, &1.deleted}) == [{"a", false}, {"b", true}]

    state = Log.fold(Log.fold(events) ++ new)
    assert Enum.map(state, & &1.record) == [%{item: "Rent", cost: "1100.00"}]

    workbook
  end

  @doc "A table is created and filled in one request, then updated, soft-deleted and compacted."
  def a_table_cycles(%Workbook{} = workbook, sheet) do
    table = Table.new(sheet, item: :string, cost: :decimal, paid: :boolean)

    inserts = [
      Table.insert(%{item: "Rent", cost: "1000.00", paid: false}, id: "rent"),
      Table.insert(%{item: "Food", cost: "400.00", paid: false}, id: "food")
    ]

    plan = Table.create(table) ++ Table.plan!(inserts, Table.empty(table))
    {:ok, workbook} = Sheetshow.run(plan, workbook)

    {:ok, snapshot} = Table.read(table, workbook)
    assert Enum.map(snapshot.rows, &{&1.id, &1.row}) == [{"rent", 1}, {"food", 2}]

    changes = [Table.update("rent", %{paid: true}), Table.delete("food")]
    {:ok, snapshot} = Table.refresh(snapshot, workbook)
    {:ok, workbook} = changes |> Table.plan!(snapshot) |> Sheetshow.run(workbook)

    {:ok, snapshot} = Table.read(table, workbook)
    assert [%{id: "rent", record: %{paid: true, cost: "1000.00"}}] = Table.live(snapshot)
    assert [%{id: "food", deleted: true}] = Enum.reject(snapshot.rows, &(&1.id == "rent"))

    {:ok, workbook} = Sheetshow.run(Table.compact(snapshot), workbook)
    {:ok, snapshot} = Table.read(table, workbook)
    assert Enum.map(snapshot.rows, & &1.id) == ["rent"]

    workbook
  end

  # Plans the cells and writes them, making any tab they name on the way: the
  # same helper the integration suite has, so a tab costs no request of its own.
  defp write(workbook, cells) do
    {:ok, workbook} =
      cells
      |> Sheetshow.plan!(existing_sheets: Workbook.titles(workbook))
      |> Sheetshow.run(workbook)

    workbook
  end
end
