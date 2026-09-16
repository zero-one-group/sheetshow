defmodule Sheetshow.WorkbookTest do
  use ExUnit.Case, async: true

  doctest Sheetshow.Workbook
  doctest Sheetshow.Client

  alias Sheetshow.{Memory, Store, Workbook}

  describe "building one" do
    test "over Google, from an id or from a client" do
      from_id = Workbook.google("1AbC", scopes: ["a"])
      from_client = Workbook.google(Sheetshow.Client.new("1AbC", scopes: ["a"]))

      assert from_id.backend == Sheetshow.Google.Backend
      assert from_id.ref.spreadsheet_id == "1AbC"
      assert from_id.ref.scopes == ["a"]
      assert from_id == from_client
    end

    test "a client carries its own options, so none are taken with it" do
      client = Sheetshow.Client.new("1AbC")

      assert_raise ArgumentError, ~r/Sheetshow.Client.new\/2/, fn ->
        Workbook.google(client, scopes: ["a"])
      end
    end

    test "over a memory, from titles or from one you hold" do
      from_titles = Workbook.memory(["log"])
      from_memory = Workbook.memory(Memory.new(["log"]))

      assert from_titles.backend == Sheetshow.Memory.Backend
      assert from_titles == from_memory
      assert from_titles.sheets == %{"log" => nil}
    end

    test "over a file, from a path or from a store" do
      from_path = Workbook.xlsx("costs.xlsx")
      from_store = Workbook.xlsx(Store.local("costs.xlsx"))

      assert from_path.backend == Sheetshow.Xlsx.Backend
      assert from_path == from_store
    end

    test "a file backend is told whether it may create the file" do
      refute Workbook.xlsx("costs.xlsx").meta.create
      assert Workbook.xlsx("costs.xlsx", create: true).meta.create
    end
  end

  describe "what it knows" do
    test "a workbook starts knowing no sheets until it is connected" do
      assert Workbook.google("1AbC").sheets == %{}
      assert Workbook.xlsx("costs.xlsx").sheets == %{}
    end

    test "titles come back sorted, whatever order they went in" do
      assert Workbook.memory(["log", "Costs", "a"]) |> Workbook.titles() ==
               ["Costs", "a", "log"]
    end

    test "a sheet's id is whatever the backend calls it, and nil where it has no name" do
      assert Workbook.memory(["log"]).sheets == %{"log" => nil}
    end
  end
end
