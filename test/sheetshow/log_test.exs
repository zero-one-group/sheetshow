defmodule Sheetshow.LogTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.Log
  doctest Sheetshow.Log.Event

  alias Sheetshow.{Error, Log, Memory}
  alias Sheetshow.Log.Event
  alias Sheetshow.Op.{AddSheet, AppendRows, PutCells}

  defp log(schema \\ [item: :string, cost: :decimal]), do: Log.new("expenses", schema)

  # The tab as a person would see it, header included.
  defp table(memory) do
    "expenses" |> Memory.read!(memory) |> Sheetshow.to_rows()
  end

  defp written(events, log \\ log()) do
    Memory.run!(Log.plan!(events, log), Memory.run!(Log.create(log), Memory.new()))
  end

  describe "new/2" do
    test "raises on a schema the validator refuses, rather than failing at the write" do
      assert_raise ArgumentError, ~r/unknown column type/, fn ->
        Log.new("expenses", item: :text)
      end
    end

    test "raises on a schema that reuses a reserved column" do
      assert_raise ArgumentError, ~r/reserved/, fn -> Log.new("expenses", id: :string) end
      assert_raise ArgumentError, ~r/reserved/, fn -> Log.new("expenses", deleted: :boolean) end
    end
  end

  describe "Event.new/2" do
    test "an option it does not take is a mistake worth raising on" do
      assert_raise ArgumentError, ~r/unknown keys \[:ids\]/, fn ->
        Event.new(%{item: "x"}, ids: "x")
      end
    end
  end

  describe "header and create" do
    test "the header is id, deleted, then the schema in its own order" do
      assert Log.columns(log()) == ["id", "deleted", "item", "cost"]
    end

    test "the header cells are bold by default and land on the log's sheet" do
      [first | _] = cells = Log.header(log())

      assert first.style == %{bold: true}
      assert first.coord.sheet == "expenses"
      assert Sheetshow.to_rows(cells) == [["id", "deleted", "item", "cost"]]
    end

    test "a style of your own replaces the default" do
      assert Log.header(log(), %{}) |> hd() |> Map.fetch!(:style) == %{}
    end

    test "create adds the tab and writes the header" do
      assert [%AddSheet{title: "expenses"}, %PutCells{sheet: "expenses"}] = Log.create(log())

      assert table(Memory.run!(Log.create(log()), Memory.new())) == [
               ["id", "deleted", "item", "cost"]
             ]
    end

    test "creating a tab that is there fails at the backend, as create should" do
      memory = Memory.run!(Log.create(log()), Memory.new())

      assert {:error, %Error{reason: :duplicate_sheet}} = Memory.run(Log.create(log()), memory)
    end
  end

  describe "view/2" do
    test "the header leaves out the deleted column, since every row shown is not" do
      cells = Log.view(log(), "now")

      assert Sheetshow.to_rows(cells) |> hd() == ["id", "item", "cost"]
      assert hd(cells).coord.sheet == "now"
    end

    test "one formula, below the header, reading the log's own columns" do
      [formula] = Enum.filter(Log.view(log(), "now"), &match?({:formula, _}, &1.value))
      {:formula, text} = formula.value

      assert formula.coord == Sheetshow.Coord.new(1, 0, "now")
      assert String.starts_with?(text, "=")
      # id, deleted, item, cost, so the source runs to D, and D is dropped.
      assert text =~ "expenses!A2:D"
      assert text =~ "CHOOSECOLS("
      assert text =~ ", 1, 3, 4)"
    end

    test "a sheet name that needs quoting gets it" do
      [formula] =
        Log.new("expenses 2026", item: :string)
        |> Log.view("now")
        |> Enum.filter(&match?({:formula, _}, &1.value))

      assert elem(formula.value, 1) =~ "'expenses 2026'!A2:C"
    end
  end

  describe "plan/2" do
    test "a batch of events is one AppendRows, so it lands or it does not" do
      events = [Event.new(%{item: "Rent"}), Event.new(%{item: "Food"})]

      assert {:ok, [%AppendRows{sheet: "expenses"} = op]} = Log.plan(events, log())
      assert AppendRows.height(op) == 2
    end

    test "no events is no plan" do
      assert Log.plan([], log()) == {:ok, []}
    end

    test "the deleted column is blank on a live row and only set on a tombstone" do
      memory = written([Event.new(%{item: "Rent"}, id: "a"), Event.delete("a")])

      assert table(memory) == [
               ["id", "deleted", "item", "cost"],
               ["a", nil, "Rent", nil],
               ["a", true, nil, nil]
             ]
    end

    test "a deleted event keeps its record, so the tab says what went" do
      event = Event.new(%{item: "Food", cost: "400.00"}, id: "b")
      memory = written([Event.delete(event)])

      assert table(memory) == [
               ["id", "deleted", "item", "cost"],
               ["b", true, "Food", "400.00"]
             ]
    end

    test "a date carries the format that makes it readable, as the planner would have given it" do
      log = log(on: :date)
      [op] = Log.plan!([Event.new(%{on: ~D[2026-09-13]}, id: "a")], log)
      cell = Enum.find(op.cells, &(&1.coord.col == 2))

      assert cell.value == ~D[2026-09-13]
      assert cell.style == %{number_format: "yyyy-mm-dd"}
    end

    test "refuses a record the schema does not fit, naming the event" do
      event = Event.new(%{cost: "free"}, id: "a")

      assert {:error, %Error{reason: :invalid_record, details: details}} =
               Log.plan([event], log(cost: :integer))

      assert details.column == :cost
      assert details.event == event
    end

    test "refuses a column the schema has never heard of" do
      assert {:error, %Error{reason: :unknown_column}} =
               Log.plan([Event.new(%{nope: 1}, id: "a")], log())
    end

    test "refuses an event with no id, which a lenient read can hand you" do
      assert {:error, %Error{reason: :missing_id}} = Log.plan([%Event{record: %{}}], log())
    end

    test "plan! raises what plan returns" do
      assert_raise Error, fn -> Log.plan!([%Event{}], log()) end
    end
  end

  describe "round trip" do
    test "what goes in comes back, for every type" do
      schema = [
        a: :string,
        b: :integer,
        c: :float,
        d: :boolean,
        e: :date,
        f: :datetime,
        g: :time,
        h: :decimal,
        i: :json
      ]

      record = %{
        a: "text",
        b: 42,
        c: 2.5,
        d: true,
        e: ~D[2026-09-13],
        f: ~N[2026-09-13 08:30:00],
        g: ~T[08:30:00],
        h: "1000.00",
        i: %{"nested" => [1, 2]}
      }

      log = log(schema)
      memory = written([Event.new(record, id: "a")], log)

      assert {:ok, [event]} = memory |> table() |> Log.decode(log)
      assert event.record == record
      assert event.errors == %{}
      assert event.id == "a"
      assert event.row == 1
    end

    test "an update and a delete leave the log as it stands" do
      log = log()
      rent = Event.new(%{item: "Rent", cost: "1000.00"}, id: "a")
      food = Event.new(%{item: "Food", cost: "400.00"}, id: "b")

      memory = written([rent, food], log)
      later = [Event.put(rent, %{cost: "1100.00"}), Event.delete(food)]
      memory = Memory.run!(Log.plan!(later, log), memory)

      assert {:ok, events} = memory |> table() |> Log.decode(log)
      assert length(events) == 4

      assert events |> Log.fold() |> Enum.map(& &1.record) == [
               %{item: "Rent", cost: "1100.00"}
             ]
    end
  end

  describe "a cursor read on a widened tab" do
    test "finds a column a hand-added one pushed right, the way a whole read does" do
      # A person widened the tab with a "notes" column, so "value" sits in D. A
      # whole read locates it by name; the cursor read bounded its columns to the
      # schema's width and truncated it, failing with :missing_column. It now reads
      # the header whole and reaches the real column.
      log = Log.new("log", value: :string)

      cells =
        Sheetshow.stack([
          Sheetshow.row(["id", "deleted", "notes", "value"]),
          Sheetshow.rows([["a", "", "n1", "one"], ["b", "", "n2", "two"]])
        ])
        |> Sheetshow.put_sheet("log")

      memory = Memory.run!(Sheetshow.plan!(cells, existing_sheets: []), Memory.new())
      workbook = Sheetshow.Workbook.memory(memory)

      {:ok, [cursor | _]} = Log.read(log, workbook)

      assert {:ok, since} = Log.read(log, workbook, after: cursor)
      assert Enum.map(since, & &1.record.value) == ["two"]
    end
  end

  describe "decode/3" do
    test "finds its columns by name, whatever case and spacing they are in" do
      rows = [[" ID ", "Deleted", "ITEM", "cost"], ["a", nil, "Rent", "1000.00"]]

      assert {:ok, [event]} = Log.decode(rows, log())
      assert event.record == %{item: "Rent", cost: "1000.00"}
    end

    test "ignores columns a person added to the right" do
      rows = [["id", "deleted", "item", "cost", "notes"], ["a", nil, "Rent", "1.00", "paid"]]

      assert {:ok, [event]} = Log.decode(rows, log())
      assert event.record == %{item: "Rent", cost: "1.00"}
    end

    test "a column that has been renamed fails loudly rather than reading its neighbour" do
      assert {:error, %Error{reason: :missing_column, details: %{column: "cost"}}} =
               Log.decode([["id", "deleted", "item", "price"]], log())
    end

    test "reads the columns where they are, not where the schema put them" do
      rows = [["cost", "item", "deleted", "id"], ["1.00", "Rent", nil, "a"]]

      assert {:ok, [event]} = Log.decode(rows, log())
      assert {event.id, event.record} == {"a", %{item: "Rent", cost: "1.00"}}
    end

    test "skips blank rows and keeps the row numbers honest" do
      rows = [
        ["id", "deleted", "item", "cost"],
        ["a", nil, "Rent", "1.00"],
        [nil, "", nil, nil],
        ["b", nil, "Food", "2.00"]
      ]

      assert {:ok, events} = Log.decode(rows, log())
      assert Enum.map(events, &{&1.id, &1.row}) == [{"a", 1}, {"b", 3}]
    end

    test "a row with content and no id is kept and flagged, so nothing a person typed vanishes" do
      rows = [["id", "deleted", "item", "cost"], [nil, nil, "Rent", "1.00"]]

      assert {:ok, [event]} = Log.decode(rows, log())
      assert event.id == nil
      assert event.record == %{item: "Rent", cost: "1.00"}
      assert %{id: %Error{reason: :cast}} = event.errors
      assert Event.errors?(event)
    end

    test "an id someone typed as a number still reads" do
      rows = [["id", "deleted", "item", "cost"], [104, nil, "Rent", "1.00"]]

      assert {:ok, [event]} = Log.decode(rows, log())
      assert event.id == "104"
    end

    test "a cell that will not cast costs that field and nothing else" do
      rows = [["id", "deleted", "item", "cost"], ["a", nil, "Rent", "free"]]

      assert {:ok, [event]} = Log.decode(rows, log())
      assert event.record == %{item: "Rent", cost: nil}
      assert %{cost: %Error{reason: :cast}} = event.errors
    end

    test "a deleted flag nobody can read leaves the row live and says so" do
      rows = [["id", "deleted", "item", "cost"], ["a", "perhaps", "Rent", "1.00"]]

      assert {:ok, [event]} = Log.decode(rows, log())
      refute event.deleted
      assert %{deleted: %Error{reason: :cast}} = event.errors
      assert Log.fold([event]) == [event]
    end

    test "strict refuses the read and names the first bad cell" do
      log = log(item: :string, cost: :integer)

      rows = [
        ["id", "deleted", "item", "cost"],
        ["a", nil, "Rent", 10],
        ["b", nil, "Food", "free"]
      ]

      assert {:ok, _lenient} = Log.decode(rows, log)

      assert {:error, %Error{reason: :cast, details: details} = error} =
               Log.decode(rows, log, strict: true)

      assert details.row == 2
      assert details.column == :cost
      assert details.value == "free"
      assert details.flagged == 1
      assert Exception.message(error) =~ "row 2"
    end

    test "strict passes a clean read straight through" do
      rows = [["id", "deleted", "item", "cost"], ["a", nil, "Rent", "1.00"]]

      assert {:ok, [%Event{}]} = Log.decode(rows, log(), strict: true)
    end

    test "a header given separately makes the rows data, numbered from :row" do
      header = ["id", "deleted", "item", "cost"]
      rows = [["a", nil, "Rent", "1.00"], ["b", nil, "Food", "2.00"]]

      assert {:ok, events} = Log.decode(rows, log(), header: header, row: 900)
      assert Enum.map(events, & &1.row) == [900, 901]
    end

    test "decode! raises what decode returns" do
      assert_raise Error, fn -> Log.decode!([["id"]], log()) end
    end
  end

  describe "fold/1" do
    defp event(id, item, opts \\ []) do
      %Event{
        id: id,
        row: Keyword.get(opts, :row),
        record: %{item: item},
        deleted: Keyword.get(opts, :deleted, false)
      }
    end

    test "the last event for an id wins" do
      folded = Log.fold([event("a", "Rent"), event("a", "Mortgage")])

      assert Enum.map(folded, & &1.record.item) == ["Mortgage"]
    end

    test "the order is the order the ids first appeared, not the order they were last touched" do
      events = [event("a", "Rent"), event("b", "Food"), event("a", "Mortgage")]

      assert Log.fold(events) |> Enum.map(& &1.id) == ["a", "b"]
    end

    test "a tombstone takes the id out" do
      events = [event("a", "Rent"), event("b", "Food"), event("a", "Rent", deleted: true)]

      assert Log.fold(events) |> Enum.map(& &1.id) == ["b"]
    end

    test "an id written again after a tombstone comes back" do
      events = [event("a", "Rent"), event("a", "Rent", deleted: true), event("a", "Rent again")]

      assert Log.fold(events) |> Enum.map(& &1.record.item) == ["Rent again"]
    end

    test "a folded log folds again: batches can be merged instead of re-read" do
      old = [event("a", "Rent"), event("b", "Food"), event("a", "Mortgage")]
      new = [event("c", "Fuel"), event("b", "Food", deleted: true), event("a", "Rent")]

      assert Log.fold(Log.fold(old) ++ new) == Log.fold(old ++ new)
    end

    test "the exception to that: an id deleted and later written again moves" do
      old = [event("a", "Rent"), event("b", "Food"), event("a", "Rent", deleted: true)]
      new = [event("a", "Rent again")]

      assert Log.fold(old ++ new) |> Enum.map(& &1.id) == ["a", "b"]
      assert Log.fold(Log.fold(old) ++ new) |> Enum.map(& &1.id) == ["b", "a"]
    end

    test "rows with no id keep their places and stay out of each other's way" do
      events = [event(nil, "Rent", row: 1), event(nil, "Food", row: 2)]

      assert Log.fold(events) |> Enum.map(& &1.record.item) == ["Rent", "Food"]
    end

    test "nothing folds to nothing" do
      assert Log.fold([]) == []
    end
  end
end
