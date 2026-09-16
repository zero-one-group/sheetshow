if Sheetshow.Integration.configured?() do
  defmodule Sheetshow.Integration.TableTest do
    use ExUnit.Case, async: true

    @moduletag :integration
    @moduletag timeout: 120_000

    import Sheetshow.Integration

    alias Sheetshow.{Op, Table}

    setup_all do: connect()

    @schema [item: :string, cost: :decimal, on: :date, paid: :boolean, n: :integer]

    defp costs(title), do: Table.new(title, @schema)

    defp row(item, cost, n, opts \\ []) do
      Table.insert(
        %{item: item, cost: cost, on: ~D[2026-09-12], paid: false, n: n},
        opts
      )
    end

    test "a table is made and filled in one request, and reads back as it was written",
         %{workbook: workbook} do
      title = tab()
      table = costs(title)

      inserts = [row("Rent", "1000.00", 1, id: "a"), row("Food", "400.00", 2, id: "b")]
      plan = Table.create(table) ++ Table.plan!(inserts, Table.empty(table))

      {:ok, workbook} = Sheetshow.run(plan, workbook)

      assert {:ok, snapshot} = Table.read(table, workbook)
      assert snapshot.header == Table.columns(table)
      assert Enum.map(snapshot.rows, &{&1.id, &1.row}) == [{"a", 1}, {"b", 2}]

      assert {:ok, rent} = Table.fetch(snapshot, "a")

      assert rent.record == %{
               item: "Rent",
               cost: "1000.00",
               on: ~D[2026-09-12],
               paid: false,
               n: 1
             }

      assert rent.errors == %{}
    end

    test "an update writes the columns it names and leaves a person's column alone",
         %{workbook: workbook} do
      title = tab()
      table = costs(title)

      # A tab as somebody would keep it: the schema's columns, and one of their
      # own to the right that Sheetshow has no business writing to.
      workbook =
        write(
          workbook,
          Sheetshow.rows(
            [
              Table.columns(table) ++ ["notes"],
              ["a", nil, "Rent", "1000.00", ~D[2026-09-12], true, 1, "ask about the deposit"]
            ],
            sheet: title
          )
        )

      assert {:ok, snapshot} = Table.read(table, workbook)
      assert List.last(snapshot.header) == "notes"

      plan = Table.plan!([Table.update("a", %{cost: "1100.00"})], snapshot)
      {:ok, workbook} = Sheetshow.run(plan, workbook)

      assert {:ok, after_write} = Table.read(table, workbook)
      assert {:ok, rent} = Table.fetch(after_write, "a")

      assert rent.record.cost == "1100.00"
      assert rent.record.item == "Rent"
      assert rent.record.paid == true
      assert rent.record.on == ~D[2026-09-12]

      # Their column, and the row's id, both still there.
      assert {:ok, [_header, written]} = Sheetshow.read_rows(quoted(title), workbook)
      assert List.last(written) == "ask about the deposit"
      assert List.first(written) == "a"
    end

    test "a soft delete hides a row without moving anything, and compact takes it off",
         %{workbook: workbook} do
      title = tab()
      table = costs(title)

      inserts = for {item, n} <- [{"Rent", 1}, {"Food", 2}, {"Fuel", 3}], do: row(item, "1.00", n)
      plan = Table.create(table) ++ Table.plan!(inserts, Table.empty(table))
      {:ok, workbook} = Sheetshow.run(plan, workbook)

      [rent, food, _fuel] = Enum.map(inserts, & &1.id)

      assert {:ok, snapshot} = Table.read(table, workbook)

      {:ok, workbook} =
        [Table.delete(rent), Table.delete(food)]
        |> Table.plan!(snapshot)
        |> Sheetshow.run(workbook)

      assert {:ok, deleted} = Table.read(table, workbook)

      # Hidden, but still there and still where they were, which is the whole
      # difference between a soft delete and a hard one.
      assert deleted |> Table.live() |> Enum.map(& &1.record.item) == ["Fuel"]

      assert Enum.map(deleted.rows, &{&1.record.item, &1.row}) ==
               [{"Rent", 1}, {"Food", 2}, {"Fuel", 3}]

      {:ok, workbook} = deleted |> Table.compact() |> Sheetshow.run(workbook)

      assert {:ok, tidied} = Table.read(table, workbook)
      assert Enum.map(tidied.rows, &{&1.record.item, &1.row}) == [{"Fuel", 1}]
    end

    test "several hard deletes apply bottom-up, and an update above them still lands",
         %{workbook: workbook} do
      title = tab()
      table = costs(title)

      inserts =
        for {item, n} <- [{"Rent", 1}, {"Food", 2}, {"Fuel", 3}, {"Tea", 4}],
            do: row(item, "1.00", n)

      plan = Table.create(table) ++ Table.plan!(inserts, Table.empty(table))
      {:ok, workbook} = Sheetshow.run(plan, workbook)

      [rent, food, _fuel, tea] = Enum.map(inserts, & &1.id)

      assert {:ok, snapshot} = Table.read(table, workbook)

      changes = [
        Table.update(rent, %{n: 10}),
        Table.delete(food, hard: true),
        Table.delete(tea, hard: true)
      ]

      {:ok, workbook} = changes |> Table.plan!(snapshot) |> Sheetshow.run(workbook)

      assert {:ok, after_write} = Table.read(table, workbook)

      assert Enum.map(after_write.rows, &{&1.record.item, &1.record.n, &1.row}) ==
               [{"Rent", 10, 1}, {"Fuel", 3, 2}]
    end

    test "a refresh finds the rows that moved, and the changes still fit", %{workbook: workbook} do
      title = tab()
      table = costs(title)

      inserts = for {item, n} <- [{"Rent", 1}, {"Food", 2}, {"Fuel", 3}], do: row(item, "1.00", n)
      plan = Table.create(table) ++ Table.plan!(inserts, Table.empty(table))
      {:ok, workbook} = Sheetshow.run(plan, workbook)

      [_rent, food, fuel] = Enum.map(inserts, & &1.id)

      assert {:ok, snapshot} = Table.read(table, workbook)
      assert {:ok, %{row: 3}} = Table.fetch(snapshot, fuel)

      # Somebody else takes a row out from under us, so the snapshot now points a
      # row too low, which is exactly what a refresh is for.
      {:ok, workbook} = Sheetshow.run([Op.DeleteRows.new(title, 1..1)], workbook)

      assert {:ok, refreshed} = Table.refresh(snapshot, workbook)
      assert Enum.map(refreshed.rows, &{&1.id, &1.row}) == [{food, 1}, {fuel, 2}]

      {:ok, workbook} =
        [Table.update(fuel, %{item: "Diesel"})]
        |> Table.plan!(refreshed)
        |> Sheetshow.run(workbook)

      assert {:ok, after_write} = Table.read(table, workbook)
      assert Enum.map(after_write.rows, &{&1.row, &1.record.item}) == [{1, "Food"}, {2, "Diesel"}]
    end
  end
end
