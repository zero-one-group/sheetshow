defmodule Sheetshow.BackendTest do
  use ExUnit.Case, async: true

  doctest Sheetshow.Backend

  alias Sheetshow.{Backend, Error, Memory, Op, Workbook}

  @backends [
    {Sheetshow.Google.Backend, Sheetshow.Workbook.google("1AbC")},
    {Sheetshow.Memory.Backend, Sheetshow.Workbook.memory()}
  ]

  describe "the behaviour" do
    test "every backend implements every required callback" do
      optional = Backend.behaviour_info(:optional_callbacks)
      required = Backend.behaviour_info(:callbacks) -- optional

      for {backend, _workbook} <- @backends, {fun, arity} <- required do
        # function_exported?/3 answers for a *loaded* module, so without this it
        # depends on whether some earlier test happened to load the backend.
        Code.ensure_loaded!(backend)

        assert function_exported?(backend, fun, arity),
               "#{inspect(backend)} does not export #{fun}/#{arity}"
      end
    end

    test "every backend answers for every capability there is" do
      for {backend, workbook} <- @backends do
        capabilities = backend.capabilities(workbook)

        assert Enum.sort(Map.keys(capabilities)) == Enum.sort(Backend.known()),
               "#{inspect(backend)} does not answer for every capability"

        assert Enum.all?(Map.values(capabilities), &is_boolean/1)
      end
    end
  end

  describe "capabilities" do
    test "are read off the workbook's backend" do
      memory = Workbook.memory()
      google = Workbook.google("1AbC")

      assert Backend.capabilities(memory) == Sheetshow.Memory.Backend.capabilities(memory)
      assert Backend.capabilities(google) == Sheetshow.Google.Backend.capabilities(google)
    end

    test "the two backends are not equals: Google works formulas out and a memory does not" do
      assert Backend.supports?(Workbook.google("1AbC"), :evaluates_formulas)
      refute Backend.supports?(Workbook.memory(), :evaluates_formulas)
    end

    test "neither can promise a conditional write, which is the gap Table lives with" do
      refute Backend.supports?(Workbook.google("1AbC"), :conditional_write)
      refute Backend.supports?(Workbook.memory(), :conditional_write)
    end

    test "both resolve an append at the moment it is applied, which is what Log rests on" do
      assert Backend.supports?(Workbook.google("1AbC"), :server_side_append)
      assert Backend.supports?(Workbook.memory(), :server_side_append)
    end
  end

  describe "ensure" do
    test "is :ok when the backend promises it" do
      assert :ok = Backend.ensure(Workbook.memory(), :atomic_batch)
    end

    test "names the backend and the capability when it does not" do
      assert {:error, %Error{reason: :unsupported} = error} =
               Backend.ensure(Workbook.memory(), :evaluates_formulas)

      assert error.details == %{
               backend: Sheetshow.Memory.Backend,
               capability: :evaluates_formulas
             }

      assert Exception.message(error) =~ "does not support :evaluates_formulas"
    end
  end

  describe "a backend with no credentials" do
    test "says so rather than pretending to authenticate" do
      assert {:error, %Error{reason: :unsupported} = error} =
               Sheetshow.authenticate(Workbook.memory())

      assert Exception.message(error) =~ "no credentials to trade"
    end

    test "connects for free, and connecting twice changes nothing" do
      workbook = Workbook.memory(["Costs"])
      assert {:ok, connected} = Sheetshow.connect(workbook)
      assert {:ok, ^connected} = Sheetshow.connect(connected)
      assert connected.sheets == %{"Costs" => nil}
    end
  end

  describe "the in-memory backend behind the seam" do
    test "runs a plan and reads it back through the same functions Google uses" do
      workbook = Workbook.memory()

      cells =
        Sheetshow.stack([
          Sheetshow.row(["Item", "Cost"]),
          Sheetshow.row(["Rent", 1000])
        ])
        |> Sheetshow.put_sheet("Costs")

      assert {:ok, workbook} =
               cells |> Sheetshow.plan!(existing_sheets: []) |> Sheetshow.run(workbook)

      assert {:ok, read} = Sheetshow.read_cells("Costs!A1:B2", workbook)
      assert Sheetshow.to_rows(read) == [["Item", "Cost"], ["Rent", 1000]]
    end

    test "a plan that creates a sheet leaves the workbook knowing about it" do
      workbook = Workbook.memory()
      assert workbook.sheets == %{}

      assert {:ok, workbook} = Sheetshow.run([Op.AddSheet.new("log")], workbook)
      assert workbook.sheets == %{"log" => nil}

      assert {:ok, workbook} = Sheetshow.run([Op.DeleteSheet.new("log")], workbook)
      assert workbook.sheets == %{}
    end

    test "a failed plan leaves the workbook it was given" do
      workbook = Workbook.memory()
      put = Op.PutCells.new(Sheetshow.row([1], sheet: "nope"))

      assert {:error, %Error{reason: :unknown_sheet}} = Sheetshow.run([put], workbook)
    end

    test "the memory itself is on the workbook, so it can be taken back out" do
      workbook = Workbook.memory(["Costs"])
      assert %Memory{} = workbook.ref
      assert Memory.titles(workbook.ref) == ["Costs"]
    end

    test "read_rows gives rows the way the values endpoint does" do
      workbook = Workbook.memory(["log"])
      cells = Sheetshow.rows([["id", "cost"], ["a", 1], ["b", 2]], sheet: "log")

      assert {:ok, workbook} =
               cells |> Sheetshow.plan!(existing_sheets: ["log"]) |> Sheetshow.run(workbook)

      assert {:ok, rows} = Sheetshow.read_rows("log", workbook)
      assert rows == [["id", "cost"], ["a", 1], ["b", 2]]
    end

    test "read_rows counts from the range's own first row, not the sheet's" do
      workbook = Workbook.memory(["log"])
      cells = Sheetshow.rows([["id"], ["a"], ["b"]], sheet: "log")

      assert {:ok, workbook} =
               cells |> Sheetshow.plan!(existing_sheets: ["log"]) |> Sheetshow.run(workbook)

      assert {:ok, rows} = Sheetshow.read_rows("log!A2:A", workbook)
      assert rows == [["a"], ["b"]]
    end

    test "a range with nothing in it is no rows at all" do
      workbook = Workbook.memory(["log"])
      assert {:ok, []} = Sheetshow.read_rows("log!A1:C10", workbook)
    end

    test "several ranges come back in the order they were asked for" do
      workbook = Workbook.memory(["log"])
      cells = Sheetshow.rows([["id", "cost"], ["a", 1]], sheet: "log")

      assert {:ok, workbook} =
               cells |> Sheetshow.plan!(existing_sheets: ["log"]) |> Sheetshow.run(workbook)

      assert {:ok, [header, ids]} =
               Sheetshow.read_rows(["log!A1:B1", "log!A2:A"], workbook)

      assert header == [["id", "cost"]]
      assert ids == [["a"]]
    end

    test "reading needs a sheet here too" do
      assert {:error, %Error{reason: :invalid_range}} =
               Sheetshow.read_rows("A1:B2", Workbook.memory(["log"]))
    end
  end
end
