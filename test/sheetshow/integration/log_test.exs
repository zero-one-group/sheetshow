if Sheetshow.Integration.configured?() do
  defmodule Sheetshow.Integration.LogTest do
    use ExUnit.Case, async: true

    @moduletag :integration
    @moduletag timeout: 120_000

    import Sheetshow.Integration

    alias Sheetshow.{Google, Cell, Coord, Fixtures, Google, Log, Value}

    setup_all do: connect()

    @schema [item: :string, cost: :decimal, on: :date, paid: :boolean, n: :integer]

    defp events do
      rent = Log.Event.new(%{item: "Rent", cost: "1000.00", on: ~D[2026-09-12], paid: true, n: 1})
      food = Log.Event.new(%{item: "Food", cost: "400.00", on: ~D[2026-09-13], paid: false, n: 2})

      [rent, food, Log.Event.put(rent, %{cost: "1100.00"}), Log.Event.delete(food)]
    end

    # The tab, the header and the events in one batch. Plans are lists, so the
    # `AddSheet` and `PutCells` the header needs and the `AppendRows` the events
    # need concatenate; Google applies them in order, so the appends still land
    # below a header that did not exist when the batch was sent.
    defp started(workbook, log) do
      plan =
        Sheetshow.plan!(Log.header(log), existing_sheets: Map.keys(workbook.sheets)) ++
          Log.plan!(events(), log)

      {:ok, workbook} = Sheetshow.run(plan, workbook)
      workbook
    end

    test "the two read paths give the same events, and one of them is much smaller",
         %{workbook: workbook} do
      title = tab()
      log = Log.new(title, @schema)
      workbook = started(workbook, log)

      {:ok, values_answer} = Google.Backend.get_values(quoted(title), workbook)
      {:ok, cells_answer} = Google.Backend.get(quoted(title), workbook)
      Fixtures.record("log_values", values_answer, spreadsheet_id())
      Fixtures.record("log_cells", cells_answer, spreadsheet_id())

      from_values = values_answer |> Google.decode_values() |> Log.decode!(log)

      from_cells =
        cells_answer |> Google.decode() |> Sheetshow.to_rows() |> Log.decode!(log)

      assert from_values == from_cells
      assert Enum.map(from_values, & &1.row) == [1, 2, 3, 4]
      assert Enum.all?(from_values, &(&1.errors == %{}))

      assert Log.fold(from_values) |> Enum.map(& &1.record) == [
               %{item: "Rent", cost: "1100.00", on: ~D[2026-09-12], paid: true, n: 1}
             ]

      # The whole reason the database layer reads values rather than cells. The
      # real ratio is nearer twenty; four is the claim that the order of
      # magnitude is right.
      values_size = byte_size(JSON.encode!(values_answer))
      cells_size = byte_size(JSON.encode!(cells_answer))

      assert values_size * 4 < cells_size,
             "values #{values_size} bytes, cells #{cells_size} bytes"

      # And the public path agrees with the fixture it was recorded from.
      assert Log.read(log, workbook) == {:ok, from_values}
    end

    test "a formula in a column reads as what it works out to", %{workbook: workbook} do
      title = tab()
      log = Log.new(title, @schema)
      workbook = started(workbook, log)

      # Column G is `n`: id, deleted, then the schema's five.
      formula = Cell.new(Coord.new(1, 6, title), {:formula, "=6*7"})
      workbook = write(workbook, [formula])

      assert {:ok, [event | _]} = Log.read(log, workbook)
      assert event.record.n == 42
      assert event.errors == %{}

      # Read as cells, the same row gives back the formula itself, which is
      # what makes cells writable again, and what makes them the wrong shape
      # for a stored row.
      assert {:ok, cells} = Sheetshow.read_cells(quoted(title), workbook)
      assert Enum.find(cells, &(&1.coord == Coord.new(1, 6, title))).value == {:formula, "=6*7"}
    end

    test "the view tab works the fold out in Sheets and gets the same answer", %{
      workbook: workbook
    } do
      title = tab()
      log = Log.new(title, @schema)
      workbook = started(workbook, log)

      shown = title <> " view"
      cells = Log.view(log, shown)

      {:ok, workbook} =
        cells
        |> Sheetshow.plan!(existing_sheets: Map.keys(workbook.sheets))
        |> Sheetshow.run(workbook)

      assert {:ok, rows} = Sheetshow.read_rows(quoted(shown), workbook)

      # Nothing here is Sheetshow's arithmetic: the rows below the header are
      # whatever Sheets made of one formula. If that formula is wrong they are
      # not there at all, which is worth saying plainly.
      {:formula, text} = Enum.find(cells, &match?({:formula, _}, &1.value)).value

      assert length(rows) > 1,
             "the view tab came back empty, so Sheets would not have the formula:\n#{text}"

      assert hd(rows) == ["id" | Enum.map(@schema, fn {name, _} -> to_string(name) end)]

      expected =
        for event <- log |> Log.read!(workbook) |> Log.fold() do
          values =
            Enum.map(@schema, fn {name, type} ->
              value = Map.fetch!(event.record, name)
              if type in [:date, :datetime, :time], do: Value.to_serial(value), else: value
            end)

          [event.id | values]
        end

      # By id, because the tab can only sort by what is on it while fold/1 keeps
      # first-appearance order, and the two part company for ids written inside
      # one millisecond; see `Log.view/2`. Today `events/0` leaves one row
      # standing, so this sorts nothing; it is written this way so that the day
      # it leaves two, the test still says what it means.
      assert Enum.sort_by(tl(rows), &List.first/1) == Enum.sort_by(expected, &List.first/1)
    end

    test "a row that ends in blanks comes back short, and reads the same anyway",
         %{workbook: workbook} do
      title = tab()
      log = Log.new(title, @schema)

      event =
        Log.Event.new(%{item: "Rent", cost: "1000.00", on: ~D[2026-09-12], paid: true, n: 1})

      plan =
        Sheetshow.plan!(Log.header(log), existing_sheets: Map.keys(workbook.sheets)) ++
          Log.plan!([event, Log.Event.delete(event.id)], log)

      {:ok, workbook} = Sheetshow.run(plan, workbook)

      {:ok, answer} = Google.Backend.get_values(quoted(title), workbook)
      Fixtures.record("log_sparse", answer, spreadsheet_id())

      # A tombstone made from a bare id fills two columns of seven, and Google
      # sends back only what it has: the raggedness `decode_values/1` pads.
      [header, _live, tombstone] = answer["values"]
      assert tombstone == [event.id, true]
      assert length(tombstone) < length(header)

      rows = Google.decode_values(answer)
      assert Enum.all?(rows, &(length(&1) == length(header)))
      assert Log.decode!(rows, log) |> Log.fold() == []
    end

    test "a cursor read gives back only what was appended after it", %{workbook: workbook} do
      title = tab()
      log = Log.new(title, @schema)
      workbook = started(workbook, log)

      assert {:ok, events} = Log.read(log, workbook)
      cursor = List.last(events)

      assert {:ok, []} = Log.read(log, workbook, after: cursor)

      extra = Log.Event.new(%{item: "Fuel", cost: "50.00", on: ~D[2026-09-14], paid: false, n: 3})
      {:ok, workbook} = [extra] |> Log.plan!(log) |> Sheetshow.run(workbook)

      assert {:ok, [appended]} = Log.read(log, workbook, after: cursor)
      assert appended.id == extra.id
      assert appended.row == cursor.row + 1
      assert appended.record == extra.record

      # What the whole thing is for: folding what you held plus what is new is
      # the same as reading the log again from the top.
      assert Log.fold(Log.fold(events) ++ [appended]) == Log.fold(Log.read!(log, workbook))
    end
  end
end
