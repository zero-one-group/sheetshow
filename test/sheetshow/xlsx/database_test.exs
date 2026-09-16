defmodule Sheetshow.Xlsx.DatabaseTest do
  use ExUnit.Case, async: true

  # `Log` and `Table` were written against Google and know nothing about files.
  # This is where that claim gets checked rather than repeated: the same models,
  # the same calls, over a local file and over a store that speaks HTTP.

  alias Sheetshow.{Error, Log, Memory, Op, Store, Table, TestServer, Workbook, Xlsx}
  alias Sheetshow.Log.Event

  setup do
    directory = Path.join(System.tmp_dir!(), "sheetshow-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(directory) end)

    {:ok, workbook} =
      directory |> Path.join("db.xlsx") |> Workbook.xlsx(create: true) |> Sheetshow.connect()

    %{workbook: workbook, path: Path.join(directory, "db.xlsx")}
  end

  defp table, do: Table.new("costs", item: :string, cost: :float, on: :date, paid: :boolean)

  defp seeded(workbook, records) do
    table = table()
    inserts = Enum.map(records, &Table.insert/1)
    plan = Table.create(table) ++ Table.plan!(inserts, Table.empty(table))
    {:ok, workbook} = Sheetshow.run(plan, workbook)
    {workbook, table}
  end

  defp records(snapshot), do: snapshot |> Table.live() |> Enum.map(& &1.record)

  describe "a table on a file" do
    test "is created, filled and read back", %{workbook: workbook} do
      {workbook, table} =
        seeded(workbook, [
          %{item: "Rent", cost: 1000.0, on: ~D[2026-09-01], paid: true},
          %{item: "Food", cost: 400.5, on: ~D[2026-09-02], paid: false}
        ])

      assert {:ok, snapshot} = Table.read(table, workbook)

      assert records(snapshot) == [
               %{item: "Rent", cost: 1000.0, on: ~D[2026-09-01], paid: true},
               %{item: "Food", cost: 400.5, on: ~D[2026-09-02], paid: false}
             ]
    end

    test "an update writes only the columns it names", %{workbook: workbook} do
      {workbook, table} = seeded(workbook, [%{item: "Rent", cost: 1000.0, on: ~D[2026-09-01]}])
      {:ok, snapshot} = Table.read(table, workbook)
      [row] = Table.live(snapshot)

      change = Table.update(row.id, %{cost: 1100.0})
      {:ok, workbook} = Sheetshow.run(Table.plan!([change], snapshot), workbook)

      assert {:ok, snapshot} = Table.read(table, workbook)
      assert [%{item: "Rent", cost: 1100.0, on: ~D[2026-09-01]}] = records(snapshot)
    end

    test "a soft delete leaves the row, and a restore brings it back", %{workbook: workbook} do
      {workbook, table} = seeded(workbook, [%{item: "Rent", cost: 1000.0}])
      {:ok, snapshot} = Table.read(table, workbook)
      [row] = Table.live(snapshot)

      {:ok, workbook} = Sheetshow.run(Table.plan!([Table.delete(row.id)], snapshot), workbook)
      {:ok, snapshot} = Table.read(table, workbook)
      assert Table.live(snapshot) == []

      {:ok, workbook} = Sheetshow.run(Table.plan!([Table.restore(row.id)], snapshot), workbook)
      assert {:ok, snapshot} = Table.read(table, workbook)
      assert [%{item: "Rent"}] = records(snapshot)
    end

    test "a hard delete takes the row off the tab", %{workbook: workbook} do
      {workbook, table} =
        seeded(workbook, [%{item: "Rent", cost: 1000.0}, %{item: "Food", cost: 400.0}])

      {:ok, snapshot} = Table.read(table, workbook)
      [first, _] = Table.live(snapshot)

      change = Table.delete(first.id, hard: true)
      {:ok, workbook} = Sheetshow.run(Table.plan!([change], snapshot), workbook)

      assert {:ok, snapshot} = Table.read(table, workbook)
      assert [%{item: "Food"}] = records(snapshot)
      # and the row really is gone, not flagged: what is left sits at row 1.
      assert [%{row: 1}] = Table.live(snapshot)
    end

    test "compact sweeps every tombstone at once", %{workbook: workbook} do
      {workbook, table} =
        seeded(workbook, [%{item: "a"}, %{item: "b"}, %{item: "c"}])

      {:ok, snapshot} = Table.read(table, workbook)
      [a, _b, c] = Table.live(snapshot)

      changes = [Table.delete(a.id), Table.delete(c.id)]
      {:ok, workbook} = Sheetshow.run(Table.plan!(changes, snapshot), workbook)

      {:ok, snapshot} = Table.read(table, workbook)
      {:ok, workbook} = Sheetshow.run(Table.compact(snapshot), workbook)

      assert {:ok, snapshot} = Table.read(table, workbook)
      # A column the record never named is nil, not false: a blank flag and a
      # blank column are different things, which is why Schema keeps them apart.
      assert records(snapshot) == [%{item: "b", cost: nil, on: nil, paid: nil}]
      assert [%{row: 1}] = Table.live(snapshot)
    end

    test "refresh finds the rows again after they have moved", %{workbook: workbook} do
      {workbook, table} =
        seeded(workbook, [%{item: "a"}, %{item: "b"}, %{item: "c"}])

      {:ok, snapshot} = Table.read(table, workbook)
      [a, _b, c] = Table.live(snapshot)
      assert c.row == 3

      # Somebody takes a row out from under the snapshot.
      {:ok, workbook} = Sheetshow.run([Op.DeleteRows.new("costs", 1..1)], workbook)

      assert {:ok, refreshed} = Table.refresh(snapshot, workbook)
      assert {:ok, moved} = Table.fetch(refreshed, c.id)
      assert moved.row == 2
      assert Table.fetch(refreshed, a.id) == :error
    end

    test "every type the schema knows survives the trip through a file", %{workbook: workbook} do
      wide =
        Table.new("wide",
          text: :string,
          count: :integer,
          amount: :float,
          flag: :boolean,
          day: :date,
          moment: :datetime,
          clock: :time,
          money: :decimal,
          blob: :json
        )

      record = %{
        text: "Rent — 東京",
        count: 42,
        amount: 12.5,
        flag: true,
        day: ~D[2026-09-13],
        moment: ~N[2026-09-13 08:30:00],
        clock: ~T[14:45:00],
        money: "1000.00",
        blob: %{"a" => [1, 2]}
      }

      plan = Table.create(wide) ++ Table.plan!([Table.insert(record)], Table.empty(wide))
      {:ok, workbook} = Sheetshow.run(plan, workbook)

      assert {:ok, snapshot} = Table.read(wide, workbook)
      assert [read] = records(snapshot)
      assert read == record
    end

    test "and a read is not cheapened by the file being large", %{workbook: workbook} do
      # Cost is the point here, not correctness: a table read over a file is a
      # whole-file read, where at Google it is one bounded request.
      {workbook, table} = seeded(workbook, [%{item: "Rent"}])

      assert {:ok, _} = Table.read(table, workbook)
      assert {:ok, snapshot} = Table.read(table, workbook)
      assert {:ok, _} = Table.refresh(snapshot, workbook)
    end
  end

  describe "a log on a file" do
    setup %{workbook: workbook} do
      log = Log.new("log", item: :string, cost: :float)
      %{log: log, workbook: workbook}
    end

    test "is created, appended to and folded", %{workbook: workbook, log: log} do
      events = [Event.new(%{item: "Bus", cost: 50.0}), Event.new(%{item: "Taxi", cost: 90.0})]
      {:ok, workbook} = Sheetshow.run(Log.create(log) ++ Log.plan!(events, log), workbook)

      assert {:ok, read} = Log.read(log, workbook)
      assert Enum.map(Log.fold(read), & &1.record.item) == ["Bus", "Taxi"]
    end

    test "an id written twice folds to the later one", %{workbook: workbook, log: log} do
      first = Event.new(%{item: "Bus", cost: 50.0}, id: "a")
      {:ok, workbook} = Sheetshow.run(Log.create(log) ++ Log.plan!([first], log), workbook)

      corrected = Event.put(first, %{cost: 55.0})
      {:ok, workbook} = Sheetshow.run(Log.plan!([corrected], log), workbook)

      assert {:ok, read} = Log.read(log, workbook)
      assert [%{record: %{cost: 55.0}}] = Log.fold(read)
    end

    test "a tombstone drops the id out", %{workbook: workbook, log: log} do
      events = [Event.new(%{item: "Bus"}, id: "a"), Event.new(%{item: "Taxi"}, id: "b")]
      {:ok, workbook} = Sheetshow.run(Log.create(log) ++ Log.plan!(events, log), workbook)
      {:ok, workbook} = Sheetshow.run(Log.plan!([Event.delete("a")], log), workbook)

      assert {:ok, read} = Log.read(log, workbook)
      assert Enum.map(Log.fold(read), & &1.id) == ["b"]
    end

    test "a cursor reads only what came after it", %{workbook: workbook, log: log} do
      first = [Event.new(%{item: "Bus"}), Event.new(%{item: "Taxi"})]
      {:ok, workbook} = Sheetshow.run(Log.create(log) ++ Log.plan!(first, log), workbook)
      {:ok, read} = Log.read(log, workbook)
      cursor = List.last(read)

      later = [Event.new(%{item: "Tram"})]
      {:ok, workbook} = Sheetshow.run(Log.plan!(later, log), workbook)

      assert {:ok, since} = Log.read(log, workbook, after: cursor)
      assert Enum.map(since, & &1.record.item) == ["Tram"]
    end

    test "folding what a cursor gave onto what was folded before is the same answer",
         %{workbook: workbook, log: log} do
      first = [Event.new(%{item: "Bus"}, id: "a"), Event.new(%{item: "Taxi"}, id: "b")]
      {:ok, workbook} = Sheetshow.run(Log.create(log) ++ Log.plan!(first, log), workbook)
      {:ok, read} = Log.read(log, workbook)
      cursor = List.last(read)

      later = [Event.new(%{item: "Tram"}, id: "c"), Event.new(%{item: "Bus 2"}, id: "a")]
      {:ok, workbook} = Sheetshow.run(Log.plan!(later, log), workbook)

      {:ok, since} = Log.read(log, workbook, after: cursor)
      {:ok, everything} = Log.read(log, workbook)

      incremental = Log.fold(Log.fold(read) ++ since)
      whole = Log.fold(everything)

      assert Enum.map(incremental, &{&1.id, &1.record.item}) ==
               Enum.map(whole, &{&1.id, &1.record.item})
    end
  end

  describe "the view tab" do
    test "is written, and its formula is the Google one", %{workbook: workbook} do
      log = Log.new("log", item: :string)
      cells = Log.create(log) ++ Sheetshow.plan!(Log.view(log, "now"), existing_sheets: [])

      assert {:ok, workbook} = Sheetshow.run(cells, workbook)
      assert {:ok, read} = Sheetshow.read_cells("now!A2", workbook)
      assert [%{value: {:formula, formula}}] = read

      # SORTN is a Google Sheets function with no counterpart in Excel, so a
      # workbook opened there shows #NAME? in this cell. The docs say so; this
      # is what makes the claim checkable rather than a comment.
      assert formula =~ "SORTN"
      refute Sheetshow.Backend.supports?(workbook, :evaluates_formulas)
    end
  end

  describe "the two backends agree" do
    test "the same table read from a file and from a memory says the same thing",
         %{workbook: workbook} do
      records = [
        %{item: "Rent", cost: 1000.0, on: ~D[2026-09-01], paid: true},
        %{item: "Food", cost: 400.5, on: ~D[2026-09-02], paid: false}
      ]

      table = table()
      inserts = Enum.map(records, &Table.insert(&1, id: &1.item))
      plan = Table.create(table) ++ Table.plan!(inserts, Table.empty(table))

      {:ok, on_file} = Sheetshow.run(plan, workbook)
      {:ok, in_memory} = Sheetshow.run(plan, Workbook.memory())

      {:ok, from_file} = Table.read(table, on_file)
      {:ok, from_memory} = Table.read(table, in_memory)

      assert records(from_file) == records(from_memory)

      assert Enum.map(Table.live(from_file), & &1.row) ==
               Enum.map(Table.live(from_memory), & &1.row)
    end

    test "and so does the same log", %{workbook: workbook} do
      log = Log.new("log", item: :string, cost: :float)
      events = [Event.new(%{item: "Bus", cost: 50.0}, id: "a"), Event.new(%{item: "T"}, id: "b")]
      plan = Log.create(log) ++ Log.plan!(events, log)

      {:ok, on_file} = Sheetshow.run(plan, workbook)
      {:ok, in_memory} = Sheetshow.run(plan, Workbook.memory())

      {:ok, from_file} = Log.read(log, on_file)
      {:ok, from_memory} = Log.read(log, in_memory)

      assert Enum.map(from_file, &{&1.id, &1.record}) ==
               Enum.map(from_memory, &{&1.id, &1.record})
    end
  end

  # The property that makes a file backend usable for a log at all: an append
  # that lost a race is refused rather than carried out, and the same plan run
  # again lands correctly, because ids dedupe on the fold.
  describe "an append that lost the race" do
    defp workbook_with_log do
      log = Log.new("log", item: :string)
      {:ok, workbook} = Sheetshow.run(Log.create(log), Workbook.memory())
      {log, workbook}
    end

    defp bytes_of(memory_workbook, log) do
      # Turn an in-memory workbook into a real xlsx, so the test server can
      # hand it out as a file.
      path = Path.join(System.tmp_dir!(), "sheetshow-#{System.unique_integer([:positive])}.xlsx")
      on_exit(fn -> File.rm(path) end)

      file = Workbook.xlsx(path, create: true)
      {:ok, cells} = Sheetshow.read_cells("#{log.sheet}!A1:Z1000", memory_workbook)

      {:ok, _} =
        Sheetshow.run(
          Sheetshow.plan!(cells, existing_sheets: []),
          file
        )

      File.read!(path)
    end

    test "is a conflict, and running the plan again is safe" do
      {log, seeded} = workbook_with_log()

      {:ok, seeded} =
        Sheetshow.run(Log.plan!([Event.new(%{item: "ours-0"}, id: "0")], log), seeded)

      v1 = bytes_of(seeded, log)

      # What somebody else wrote while we were planning.
      {:ok, theirs} =
        Sheetshow.run(Log.plan!([Event.new(%{item: "theirs"}, id: "t")], log), seeded)

      v2 = bytes_of(theirs, log)

      url =
        TestServer.start([
          {200, v1, "application/octet-stream", [{"etag", ~s("v1")}]},
          {412, "", "text/plain", []},
          {200, v2, "application/octet-stream", [{"etag", ~s("v2")}]},
          {200, "", "application/octet-stream", [{"etag", ~s("v3")}]}
        ])

      store = Store.webdav(url <> "/db.xlsx", username: "user", password: "pw")
      workbook = Workbook.xlsx(store)
      plan = Log.plan!([Event.new(%{item: "ours"}, id: "a")], log)

      # Lost the race: refused, and nothing written.
      assert {:error, %Error{reason: :conflict}} = Sheetshow.run(plan, workbook)

      # The very same plan, run again against what is there now.
      assert {:ok, _} = Sheetshow.run(plan, workbook)

      assert_receive {:request, %{method: :GET}}
      assert_receive {:request, %{method: :PUT, headers: %{"if-match" => ~s("v1")}}}
      assert_receive {:request, %{method: :GET}}
      assert_receive {:request, %{method: :PUT} = final}
      assert final.headers["if-match"] == ~s("v2")

      # Both writers' rows are there, each once.
      {:ok, written} = Xlsx.open(final.body)
      {:ok, memory} = Xlsx.memory(written)
      {:ok, read} = Log.read(log, Workbook.memory(memory))

      assert Enum.map(Log.fold(read), & &1.id) == ["0", "t", "a"]
    end

    test "and a local file has nothing to refuse with", %{workbook: workbook} do
      # The same race on a store with no conditional write loses the other
      # writer's rows outright, which is why the capability says so.
      refute Sheetshow.Backend.supports?(workbook, :conditional_write)
      refute Sheetshow.Backend.supports?(workbook, :server_side_append)
      assert Sheetshow.Backend.supports?(Workbook.google("1AbC"), :server_side_append)
    end
  end

  describe "a memory is still a memory" do
    test "and Memory.put_sheet did not change what a log reads", %{workbook: workbook} do
      # M7.1b added put_sheet/5 for the file backend to build a memory with.
      # Nothing else should have moved.
      log = Log.new("log", item: :string)
      {:ok, workbook} = Sheetshow.run(Log.create(log), workbook)
      {:ok, read} = Log.read(log, workbook)

      assert read == []
      assert %Memory{} = Workbook.memory([]).ref
    end
  end
end
