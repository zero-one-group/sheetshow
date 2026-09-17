defmodule Sheetshow.TableTest do
  use ExUnit.Case, async: true

  doctest Sheetshow.Table
  doctest Sheetshow.Table.Row
  doctest Sheetshow.Table.Change

  alias Sheetshow.{Workbook, Error, Log, Memory, Op, Table, TestServer, Token}
  alias Sheetshow.Table.Row

  @schema [item: :string, cost: :decimal, on: :date, paid: :boolean, n: :integer]

  defp table(sheet \\ "costs"), do: Table.new(sheet, @schema)

  defp header, do: ["id", "deleted", "item", "cost", "on", "paid", "n"]

  defp rows do
    [
      header(),
      ["a", nil, "Rent", "1000.00", 46_277, true, 1],
      ["b", true, "Food", "400.00", 46_278, false, 2]
    ]
  end

  describe "new" do
    test "keeps the tab and the schema" do
      assert %Table{sheet: "costs", schema: @schema} = table()
    end

    test "refuses a schema Schema.validate would" do
      assert_raise ArgumentError, fn -> Table.new("costs", item: :colour) end
    end
  end

  describe "decode" do
    test "gives a snapshot of rows that know where they sit" do
      assert {:ok, snapshot} = Table.decode(rows(), table())

      assert snapshot.table == table()
      assert snapshot.header == header()
      assert Enum.map(snapshot.rows, & &1.row) == [1, 2]

      assert [%Row{} = rent] = Table.live(snapshot)

      assert rent.record == %{
               item: "Rent",
               cost: "1000.00",
               on: ~D[2026-09-12],
               paid: true,
               n: 1
             }
    end

    test "a tombstone is in rows but not in live/1" do
      snapshot = Table.decode!(rows(), table())

      assert Enum.map(snapshot.rows, & &1.id) == ["a", "b"]
      assert Enum.map(Table.live(snapshot), & &1.id) == ["a"]
      assert Enum.find(snapshot.rows, &(&1.id == "b")).deleted
    end

    test "blank rows are skipped and the rows after them keep their numbers" do
      with_gap = List.insert_at(rows(), 2, [nil, "", nil])

      assert {:ok, snapshot} = Table.decode(with_gap, table())
      assert Enum.map(snapshot.rows, &{&1.id, &1.row}) == [{"a", 1}, {"b", 3}]
    end

    test "columns are found by name, whatever order the tab has them in" do
      shuffled = ["n", "paid", "on", "cost", "item", "deleted", "id"]

      reversed = [
        shuffled,
        [1, true, 46_277, "1000.00", "Rent", nil, "a"]
      ]

      assert {:ok, snapshot} = Table.decode(reversed, table())
      assert [row] = Table.live(snapshot)
      assert row.id == "a"
      assert row.record.item == "Rent"
      assert row.record.n == 1
    end

    test "a column of somebody's own, to the right, is read past and kept in the header" do
      with_extra = [
        header() ++ ["notes"],
        ["a", nil, "Rent", "1000.00", 46_277, true, 1, "ask about the deposit"]
      ]

      assert {:ok, snapshot} = Table.decode(with_extra, table())
      assert List.last(snapshot.header) == "notes"
      assert [row] = Table.live(snapshot)
      assert row.errors == %{}
      refute Map.has_key?(row.record, :notes)
    end

    test "a cell that will not cast costs the field, not the read" do
      bad = [header(), ["a", nil, "Rent", "1000.00", 46_277, true, "several"]]

      assert {:ok, snapshot} = Table.decode(bad, table())
      assert [row] = Table.live(snapshot)
      assert row.record.n == nil
      assert %Error{reason: :cast} = row.errors.n
      assert row.record.item == "Rent"
    end

    test "a row with no id is kept and flagged" do
      nameless = [header(), [nil, nil, "Rent", "1000.00", 46_277, true, 1]]

      assert {:ok, snapshot} = Table.decode(nameless, table())
      assert [row] = Table.live(snapshot)
      assert row.id == nil
      assert %Error{reason: :cast} = row.errors.id
      assert row.record.item == "Rent"
    end

    test "a header that is not there says so" do
      assert {:error, %Error{reason: :missing_header} = error} =
               Table.decode([[nil, nil]], table())

      assert error.message =~ "costs"
    end

    test "a renamed column fails loudly rather than reading as its neighbour" do
      renamed = List.replace_at(header(), 3, "price")

      assert {:error, %Error{reason: :missing_column} = error} =
               Table.decode([renamed], table())

      assert error.details.column == "cost"
    end

    test "takes the header and the first row's number apart from the rows" do
      assert {:ok, snapshot} =
               Table.decode(tl(rows()), table(), header: header(), row: 10)

      assert Enum.map(snapshot.rows, & &1.row) == [10, 11]
    end

    test "an option it does not take is a mistake worth raising on" do
      assert_raise ArgumentError, ~r/unknown keys \[:sctrict\]/, fn ->
        Table.decode(rows(), table(), sctrict: true)
      end
    end
  end

  describe "repeated ids" do
    setup do
      %{rows: rows() ++ [["a", nil, "Rent again", "1100.00", 46_279, true, 3]]}
    end

    test "the first row keeps the id and the later one is flagged", %{rows: rows} do
      assert {:ok, snapshot} = Table.decode(rows, table())
      assert [first, _tombstone, second] = snapshot.rows

      assert first.errors == %{}
      assert %Error{reason: :duplicate_id} = second.errors.id
      assert second.errors.id.details.first == 1
      assert second.record.item == "Rent again"
    end

    test "fetch gives back the first, since that is the one an id names", %{rows: rows} do
      snapshot = Table.decode!(rows, table())

      assert {:ok, row} = Table.fetch(snapshot, "a")
      assert row.row == 1
      assert row.record.item == "Rent"
    end
  end

  describe "strict" do
    test "refuses a read where a cell would not cast" do
      bad = [header(), ["a", nil, "Rent", "1000.00", 46_277, true, "several"]]

      assert {:error, %Error{reason: :cast} = error} = Table.decode(bad, table(), strict: true)
      assert error.details.row == 1
      assert error.details.column == :n
    end

    test "refuses a read where two rows share an id" do
      repeated = rows() ++ [["a", nil, "Rent again", "1100.00", 46_279, true, 3]]

      assert {:error, %Error{reason: :duplicate_id} = error} =
               Table.decode(repeated, table(), strict: true)

      assert error.message =~ "same id"
      assert error.details.row == 3
    end

    test "lets a clean read through" do
      assert {:ok, _snapshot} = Table.decode(rows(), table(), strict: true)
    end
  end

  describe "fetch and live" do
    test "fetch finds nothing for an id that is only a tombstone" do
      snapshot = Table.decode!(rows(), table())

      assert Table.fetch(snapshot, "b") == :error
      assert Table.fetch(snapshot, "nobody") == :error
    end

    test "everything else a query wants is Enum" do
      snapshot = Table.decode!(rows(), table())

      assert snapshot |> Table.live() |> Enum.filter(&(&1.record.n > 0)) |> length() == 1
    end
  end

  describe "the tab it makes" do
    test "create writes a header a read can find its columns in" do
      table = table()

      written =
        Sheetshow.rows([["a", nil, "Rent", "1000.00", 46_277, true, 1]],
          row: 1,
          sheet: "costs"
        )

      memory = Memory.run!(Table.create(table), Memory.new())
      memory = Memory.run!(Sheetshow.plan!(written), memory)

      assert Memory.titles(memory) == ["costs"]

      snapshot =
        "costs"
        |> Memory.read!(memory)
        |> Sheetshow.to_rows()
        |> Table.decode!(table)

      assert [row] = Table.live(snapshot)
      assert row.id == "a"
      assert row.row == 1
      assert row.record.item == "Rent"
    end

    test "create and fill is one plan: the appends land under a header the batch wrote" do
      table = table()

      inserts = [
        Table.insert(%{item: "Rent", n: 1}, id: "a"),
        Table.insert(%{item: "Food", n: 2}, id: "b")
      ]

      plan = Table.create(table) ++ Table.plan!(inserts, Table.empty(table))
      assert kinds(plan) == ["AddSheet", "PutCells", "AppendRows"]

      snapshot = plan |> Memory.run!(Memory.new()) |> taken(table)

      assert Enum.map(snapshot.rows, &{&1.id, &1.row, &1.record.item}) ==
               [{"a", 1, "Rent"}, {"b", 2, "Food"}]
    end

    test "its columns are the log's, since the two tabs are laid out alike" do
      assert Table.columns(table()) == Log.columns(Log.new("costs", @schema))
    end
  end

  test "a table and a log read the same rows into the same records" do
    log = Log.new("costs", @schema)

    from_table = Table.decode!(rows(), table()).rows
    from_log = Log.decode!(rows(), log)

    assert Enum.map(from_table, &{&1.id, &1.row, &1.record, &1.deleted, &1.errors}) ==
             Enum.map(from_log, &{&1.id, &1.row, &1.record, &1.deleted, &1.errors})
  end

  # The plan carried out, then read back: `Memory` is what an op means, so a
  # round trip through it is the closest thing to a spec these plans have.
  defp seeded(given \\ nil) do
    cells = Sheetshow.rows(given || rows(), sheet: "costs")
    {table(), Memory.run!(Sheetshow.plan!(cells, existing_sheets: []), Memory.new())}
  end

  defp taken(memory, table) do
    "costs" |> Memory.read!(memory) |> Sheetshow.to_rows() |> Table.decode!(table)
  end

  defp carry(memory, plan), do: Memory.run!(plan, memory)

  defp kinds(plan), do: Enum.map(plan, &(&1.__struct__ |> Module.split() |> List.last()))

  describe "update" do
    test "writes the columns it names, the id, and nothing else" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)

      plan = [Table.update("a", %{cost: "1100.00"})] |> Table.plan!(snapshot)

      assert kinds(plan) == ["PutCells", "PutCells"]

      assert plan |> Enum.map(&Op.PutCells.range/1) |> Enum.map(&Sheetshow.Range.to_a1/1) ==
               ["costs!A2", "costs!D2"]

      after_write = memory |> carry(plan) |> taken(table)
      assert {:ok, row} = Table.fetch(after_write, "a")

      assert row.record == %{
               item: "Rent",
               cost: "1100.00",
               on: ~D[2026-09-12],
               paid: true,
               n: 1
             }
    end

    test "columns next to each other are one run" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)

      plan = [Table.update("a", %{paid: false, n: 9})] |> Table.plan!(snapshot)

      assert plan |> Enum.map(&Op.PutCells.range/1) |> Enum.map(&Sheetshow.Range.to_a1/1) ==
               ["costs!A2", "costs!F2:G2"]
    end

    test "a column somebody else keeps to the right is left where it is" do
      theirs = [
        header() ++ ["notes"],
        ["a", nil, "Rent", "1000.00", 46_277, true, 1, "ask about the deposit"]
      ]

      {table, memory} = seeded(theirs)
      snapshot = taken(memory, table)

      after_write =
        memory
        |> carry(Table.plan!([Table.update("a", %{item: "Rent, revised"})], snapshot))
        |> taken(table)

      assert {:ok, row} = Table.fetch(after_write, "a")
      assert row.record.item == "Rent, revised"

      kept = "costs" |> Memory.read!(memory) |> Sheetshow.to_rows() |> Enum.at(1)
      assert List.last(kept) == "ask about the deposit"
    end

    test "a column named with nil is one you want empty" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)

      after_write =
        memory
        |> carry(Table.plan!([Table.update("a", %{cost: nil})], snapshot))
        |> taken(table)

      assert {:ok, row} = Table.fetch(after_write, "a")
      assert row.record.cost == nil
      assert row.record.item == "Rent"
    end

    test "an id the snapshot has not got says so, without asking Google" do
      {table, memory} = seeded()

      assert {:error, %Error{reason: :unknown_id} = error} =
               Table.plan([Table.update("nobody", %{n: 1})], taken(memory, table))

      assert error.details.id == "nobody"
    end

    test "an id two rows are wearing is not one row to write" do
      repeated = rows() ++ [["a", nil, "Rent again", "1100.00", 46_279, true, 3]]
      {table, memory} = seeded(repeated)

      assert {:error, %Error{reason: :duplicate_id} = error} =
               Table.plan([Table.update("a", %{n: 1})], taken(memory, table))

      assert error.message =~ "id"
    end

    test "a value the schema refuses is an error here, not a surprise in the sheet" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)

      assert {:error, %Error{reason: :invalid_record}} =
               Table.plan([Table.update("a", %{n: "several"})], snapshot)

      assert {:error, %Error{reason: :unknown_column}} =
               Table.plan([Table.update("a", %{nope: 1})], snapshot)
    end

    test "two changes to one id is a question about order nobody answered" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)

      assert {:error, %Error{reason: :conflicting_changes} = error} =
               Table.plan([Table.update("a", %{n: 1}), Table.delete("a")], snapshot)

      assert error.details.id == "a"
    end
  end

  describe "insert" do
    test "lands below the data, with an id of its own" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)

      change = Table.insert(%{item: "Fuel", cost: "50.00", n: 3})
      assert byte_size(change.id) == 26

      after_write = memory |> carry(Table.plan!([change], snapshot)) |> taken(table)

      assert [_rent, fuel] = Table.live(after_write)
      assert fuel.row == 3
      assert fuel.record.item == "Fuel"
      assert fuel.id == change.id
    end

    test "several inserts are one AppendRows" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)

      changes = [Table.insert(%{item: "Fuel"}), Table.insert(%{item: "Tea"})]
      plan = Table.plan!(changes, snapshot)

      assert kinds(plan) == ["AppendRows"]
      assert plan |> hd() |> Op.AppendRows.height() == 2

      after_write = memory |> carry(plan) |> taken(table)
      assert after_write |> Table.live() |> Enum.map(& &1.record.item) == ["Rent", "Fuel", "Tea"]
    end

    test "goes into the tab's own columns, not the schema's order" do
      shuffled = [
        ["n", "paid", "on", "cost", "item", "deleted", "id"],
        [1, true, 46_277, "1000.00", "Rent", nil, "a"]
      ]

      {table, memory} = seeded(shuffled)
      snapshot = taken(memory, table)

      change = Table.insert(%{item: "Fuel", n: 7}, id: "f")
      after_write = memory |> carry(Table.plan!([change], snapshot)) |> taken(table)

      assert {:ok, row} = Table.fetch(after_write, "f")
      assert row.record.item == "Fuel"
      assert row.record.n == 7
    end

    test "an id the tab already has is an update, not an insert" do
      {table, memory} = seeded()

      assert {:error, %Error{reason: :duplicate_id} = error} =
               Table.plan([Table.insert(%{item: "Fuel"}, id: "a")], taken(memory, table))

      assert error.details.row == 1
    end

    test "refuses an id that is not a string worth having" do
      assert_raise ArgumentError, fn -> Table.insert(%{item: "Fuel"}, id: "") end
    end
  end

  describe "delete and restore" do
    test "a soft delete sets the flag and moves nothing" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)

      plan = Table.plan!([Table.delete("a")], snapshot)
      assert kinds(plan) == ["PutCells"]

      after_write = memory |> carry(plan) |> taken(table)

      assert Table.live(after_write) == []
      assert [gone, _food] = after_write.rows
      assert gone.id == "a"
      assert gone.row == 1
      assert gone.deleted
      assert gone.record.item == "Rent"
    end

    test "restore puts one back" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)

      after_write = memory |> carry(Table.plan!([Table.restore("b")], snapshot)) |> taken(table)

      assert after_write |> Table.live() |> Enum.map(& &1.id) == ["a", "b"]
      refute Enum.find(after_write.rows, &(&1.id == "b")).deleted
    end

    test "a hard delete takes the row off the tab" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)

      plan = Table.plan!([Table.delete("a", hard: true)], snapshot)
      assert kinds(plan) == ["DeleteRows"]

      after_write = memory |> carry(plan) |> taken(table)
      assert Enum.map(after_write.rows, &{&1.id, &1.row}) == [{"b", 1}]
    end
  end

  describe "the order the ops go in" do
    setup do
      given = [
        header(),
        ["a", nil, "Rent", "1000.00", 46_277, true, 1],
        ["b", nil, "Food", "400.00", 46_278, false, 2],
        ["c", nil, "Fuel", "50.00", 46_279, false, 3],
        ["d", nil, "Tea", "5.00", 46_280, false, 4]
      ]

      {table, memory} = seeded(given)
      %{table: table, memory: memory, snapshot: taken(memory, table)}
    end

    test "updates, then the appends, then the deletes", context do
      changes = [
        Table.delete("a", hard: true),
        Table.insert(%{item: "New"}, id: "e"),
        Table.update("d", %{n: 40})
      ]

      plan = Table.plan!(changes, context.snapshot)
      assert kinds(plan) == ["PutCells", "PutCells", "AppendRows", "DeleteRows"]
    end

    test "several deletes go bottom-up, so the later ones still mean what they said",
         context do
      changes = [Table.delete("b", hard: true), Table.delete("d", hard: true)]
      plan = Table.plan!(changes, context.snapshot)

      assert Enum.map(plan, & &1.rows) == [4..4, 2..2]

      after_write = context.memory |> carry(plan) |> taken(context.table)
      assert Enum.map(after_write.rows, &{&1.id, &1.row}) == [{"a", 1}, {"c", 2}]
    end

    test "neighbours merge into one range", context do
      changes = [Table.delete("b", hard: true), Table.delete("c", hard: true)]

      assert [%Op.DeleteRows{rows: 2..3}] = Table.plan!(changes, context.snapshot)
    end

    test "an update and a delete below it both land where they meant to", context do
      changes = [Table.update("a", %{n: 10}), Table.delete("c", hard: true)]

      after_write =
        context.memory |> carry(Table.plan!(changes, context.snapshot)) |> taken(context.table)

      assert Enum.map(after_write.rows, &{&1.id, &1.record.n}) ==
               [{"a", 10}, {"b", 2}, {"d", 4}]
    end
  end

  describe "compact" do
    test "takes every tombstone off, bottom-up" do
      given = [
        header(),
        ["a", nil, "Rent", "1000.00", 46_277, true, 1],
        ["b", true, "Food", "400.00", 46_278, false, 2],
        ["c", true, "Fuel", "50.00", 46_279, false, 3],
        ["d", nil, "Tea", "5.00", 46_280, false, 4]
      ]

      {table, memory} = seeded(given)
      plan = memory |> taken(table) |> Table.compact()

      assert [%Op.DeleteRows{rows: 2..3}] = plan

      after_write = memory |> carry(plan) |> taken(table)
      assert Enum.map(after_write.rows, &{&1.id, &1.row}) == [{"a", 1}, {"d", 2}]
    end

    test "nothing to compact is an empty plan" do
      {table, memory} = seeded([header(), ["a", nil, "Rent", "1000.00", 46_277, true, 1]])
      assert memory |> taken(table) |> Table.compact() == []
    end
  end

  describe "refresh" do
    defp connected(url), do: Workbook.google("1AbC", base_url: url, token: token())

    defp token, do: Token.new("ya29.abc", DateTime.add(DateTime.utc_now(), 3600, :second))

    defp answered(tables) do
      JSON.encode!(%{
        "spreadsheetId" => "1AbC",
        "valueRanges" => Enum.map(tables, &%{"range" => "x", "values" => &1})
      })
    end

    test "asks for the header and the id column, and nothing else" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)
      url = TestServer.start([{200, answered([[header()], [["a"], ["b"]]])}])

      assert {:ok, _refreshed} = Table.refresh(snapshot, connected(url))

      assert_receive {:request, request}
      assert request.path == "/v4/spreadsheets/1AbC/values:batchGet"

      assert Enum.filter(request.params, &(elem(&1, 0) == "ranges")) == [
               {"ranges", "costs!A1:G1"},
               {"ranges", "costs!A2:A"}
             ]
    end

    test "finds the rows a hand-inserted row pushed down" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)
      assert Enum.map(snapshot.rows, & &1.row) == [1, 2]

      url = TestServer.start([{200, answered([[header()], [["x"], ["a"], ["b"]]])}])

      assert {:ok, refreshed} = Table.refresh(snapshot, connected(url))
      assert Enum.map(refreshed.rows, &{&1.id, &1.row}) == [{"a", 2}, {"b", 3}]

      # And the changes you were holding are still the right changes.
      plan = Table.plan!([Table.update("a", %{n: 9})], refreshed)

      assert plan |> Enum.map(&Op.PutCells.range/1) |> Enum.map(&Sheetshow.Range.to_a1/1) ==
               ["costs!A3", "costs!G3"]
    end

    test "a row whose id has gone drops out, and a change naming it fails in plan" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)
      url = TestServer.start([{200, answered([[header()], [["b"]]])}])

      assert {:ok, refreshed} = Table.refresh(snapshot, connected(url))
      assert Enum.map(refreshed.rows, & &1.id) == ["b"]

      assert {:error, %Error{reason: :unknown_id}} =
               Table.plan([Table.update("a", %{n: 1})], refreshed)
    end

    test "an id that now turns up twice makes its row unwritable" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)
      url = TestServer.start([{200, answered([[header()], [["a"], ["a"], ["b"]]])}])

      assert {:ok, refreshed} = Table.refresh(snapshot, connected(url))
      assert %Error{reason: :duplicate_id} = Enum.find(refreshed.rows, &(&1.id == "a")).errors.id

      assert {:error, %Error{reason: :duplicate_id}} =
               Table.plan([Table.update("a", %{n: 1})], refreshed)
    end

    test "a header that has changed is not something a refresh can put right" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)
      moved = ["deleted", "id", "item", "cost", "on", "paid", "n"]
      url = TestServer.start([{200, answered([[moved], [["a"], ["b"]]])}])

      assert {:error, %Error{reason: :moved} = error} = Table.refresh(snapshot, connected(url))
      assert error.message =~ "read the table again"
    end

    test "a column that has been renamed away says which one" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)
      renamed = List.replace_at(header(), 3, "price")
      url = TestServer.start([{200, answered([[renamed], [["a"]]])}])

      assert {:error, %Error{reason: :missing_column} = error} =
               Table.refresh(snapshot, connected(url))

      assert error.details.column == "cost"
    end

    test "blanks in the id column take up room without being rows" do
      {table, memory} = seeded()
      snapshot = taken(memory, table)
      url = TestServer.start([{200, answered([[header()], [[""], [""], ["a"], ["b"]]])}])

      assert {:ok, refreshed} = Table.refresh(snapshot, connected(url))
      assert Enum.map(refreshed.rows, &{&1.id, &1.row}) == [{"a", 3}, {"b", 4}]
    end

    # The snapshot read two rows wearing one id; since then somebody removed one
    # of them by hand. The tab is now consistent, but the snapshot holds two
    # records for that id and cannot say which one survived, so both stay
    # unwritable until a fresh read, rather than both claiming the one row.
    test "an id the snapshot read twice stays unwritable when the tab now has it once" do
      table = table()

      twice = [
        header(),
        ["a", nil, "Rent", "1000.00", 46_277, true, 1],
        Enum.at(rows(), 1),
        Enum.at(rows(), 2)
      ]

      {:ok, snapshot} = Table.decode(twice, table)

      assert Enum.map(snapshot.rows, &{&1.id, &1.row, Map.has_key?(&1.errors, :id)}) ==
               [{"a", 1, false}, {"a", 2, true}, {"b", 3, false}]

      url = TestServer.start([{200, answered([[header()], [["a"], ["b"]]])}])
      assert {:ok, refreshed} = Table.refresh(snapshot, connected(url))

      assert Enum.map(refreshed.rows, &{&1.id, &1.row}) == [{"a", 1}, {"a", 1}, {"b", 2}]
      assert Enum.all?(refreshed.rows, &(&1.id != "a" or Map.has_key?(&1.errors, :id)))

      assert {:error, %Error{reason: :duplicate_id} = error} =
               Table.plan([Table.update("a", %{n: 1})], refreshed)

      assert error.message =~ "rows 1 and 2 both had id"
      assert error.message =~ "read the table again"
      assert {:ok, [_ | _]} = Table.plan([Table.update("b", %{n: 1})], refreshed)
    end
  end

  describe "options" do
    test "an option insert or delete does not take is a mistake worth raising on" do
      assert_raise ArgumentError, ~r/unknown keys \[:ids\]/, fn ->
        Table.insert(%{item: "x"}, ids: "x")
      end

      assert_raise ArgumentError, ~r/unknown keys \[:force\]/, fn ->
        Table.delete("a", force: true)
      end
    end
  end
end
