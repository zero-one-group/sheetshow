defmodule Sheetshow.ValuesTest do
  use ExUnit.Case, async: true

  alias Sheetshow.{Workbook, Error, Fixtures, Google, Log, TestServer, Token, ULID}

  defp workbook(url), do: Workbook.google("1AbC", base_url: url, token: token())

  defp token, do: Token.new("ya29.abc", DateTime.add(DateTime.utc_now(), 3600, :second))

  defp answer(rows, range \\ "Costs!A1:B2") do
    JSON.encode!(%{"range" => range, "majorDimension" => "ROWS", "values" => rows})
  end

  describe "decode_values/1" do
    test "an answer with nothing in it is no rows" do
      assert Google.decode_values(%{}) == []
      assert Google.decode_values(%{"values" => []}) == []
    end

    test "pads the ragged rows Google sends, because it drops trailing empties" do
      answer = %{"values" => [["id", "deleted", "item"], ["a"], ["b", nil, "Food"]]}

      assert Google.decode_values(answer) == [
               ["id", "deleted", "item"],
               ["a", nil, nil],
               ["b", nil, "Food"]
             ]
    end

    test "an empty row inside the range is a row of nils, not a missing row" do
      assert Google.decode_values(%{"values" => [["a", 1], [], ["b", 2]]}) == [
               ["a", 1],
               [nil, nil],
               ["b", 2]
             ]
    end

    test "an empty cell is nil, as a gap is in to_rows" do
      assert Google.decode_values(%{"values" => [["a", "", "c"]]}) == [["a", nil, "c"]]
    end

    test "keeps the kinds JSON gives, which is what a schema casts from" do
      assert Google.decode_values(%{"values" => [[1, 2.5, true, "text", 46_277]]}) ==
               [[1, 2.5, true, "text", 46_277]]
    end

    test "a formula error arrives as its text and cannot be told from someone typing it" do
      assert Google.decode_values(%{"values" => [["#DIV/0!"]]}) == [["#DIV/0!"]]
    end
  end

  describe "the answers recorded from Google" do
    @schema [item: :string, cost: :decimal, on: :date, paid: :boolean, n: :integer]

    defp recorded(name) do
      answer = Fixtures.read(name)

      assert answer,
             "test/fixtures/#{name}.json is missing; record it with " <>
               "SHEETSHOW_RECORD_FIXTURES=1 mix check.all"

      answer
    end

    test "the values endpoint gives the kinds a schema was built to cast" do
      rows = recorded("log_values") |> Google.decode_values()

      assert hd(rows) == ["id", "deleted", "item", "cost", "on", "paid", "n"]

      [_header, first | _rest] = rows
      [id, deleted, item, cost, on, paid, n] = first

      # A date really does arrive as a serial number, a decimal really does stay
      # the text it was written as, and a blank flag is an empty string, not a
      # missing cell: the three things the read path was chosen for.
      assert ULID.valid?(id)
      assert deleted == nil
      assert {item, cost} == {"Rent", "1000.00"}
      assert on == 46_277
      assert {paid, n} == {true, 1}
    end

    test "Google leaves out the rows it has nothing for" do
      answer = recorded("log_values")

      # The request asked for the whole tab, and Google answered with the grid's
      # extent, but only with the rows that hold anything. An empty log is a
      # small request, which is what a full read every time depends on.
      assert answer["range"] =~ "A1:Z1000"
      assert length(answer["values"]) == 5
    end

    test "both read paths decode the recorded tab to the very same events" do
      log = Log.new("sheetshow N", @schema)

      from_values = recorded("log_values") |> Google.decode_values() |> Log.decode!(log)

      from_cells =
        recorded("log_cells") |> Google.decode() |> Sheetshow.to_rows() |> Log.decode!(log)

      assert from_values == from_cells
      assert Enum.map(from_values, & &1.row) == [1, 2, 3, 4]
      assert Enum.all?(from_values, &(&1.errors == %{}))
      assert Enum.map(from_values, & &1.deleted) == [false, false, false, true]

      [rent, food, again, gone] = from_values
      assert rent.id == again.id
      assert food.id == gone.id
      assert rent.id != food.id

      assert Log.fold(from_values) |> Enum.map(& &1.record) == [
               %{item: "Rent", cost: "1100.00", on: ~D[2026-09-12], paid: true, n: 1}
             ]
    end

    test "and the one is a fraction of the size of the other" do
      values = "log_values" |> Fixtures.path() |> File.stat!()
      cells = "log_cells" |> Fixtures.path() |> File.stat!()

      # The reason the database layer reads values and not cells, pinned where
      # it cannot quietly stop being true. It was nearer thirteen when recorded.
      assert values.size * 10 < cells.size
    end
  end

  describe "read_rows/2" do
    test "asks the values endpoint for unformatted values and serial dates" do
      url = TestServer.start([{200, answer([["Item", "Cost"], ["Rent", 1000]])}])

      assert {:ok, rows} = Sheetshow.read_rows("Costs!A1:B2", workbook(url))
      assert rows == [["Item", "Cost"], ["Rent", 1000]]

      assert_receive {:request, request}
      assert request.method == :GET
      assert request.path == "/v4/spreadsheets/1AbC/values/Costs!A1:B2"
      assert request.query["valueRenderOption"] == "UNFORMATTED_VALUE"
      assert request.query["dateTimeRenderOption"] == "SERIAL_NUMBER"
      assert request.headers["authorization"] == "Bearer ya29.abc"
    end

    test "escapes a sheet name that carries quotes and spaces" do
      url = TestServer.start([{200, answer([], "'sheetshow 1'!A1:B2")}])

      assert {:ok, []} = Sheetshow.read_rows("'sheetshow 1'", workbook(url))

      assert_receive {:request, request}
      assert request.path == "/v4/spreadsheets/1AbC/values/'sheetshow%201'"
    end

    test "takes a Range as well as an A1 string" do
      url = TestServer.start([{200, answer([["Rent"]])}])
      range = Sheetshow.Range.new("Costs", 0..0, 0..0)

      assert {:ok, [["Rent"]]} = Sheetshow.read_rows(range, workbook(url))

      assert_receive {:request, request}
      assert request.path == "/v4/spreadsheets/1AbC/values/Costs!A1"
    end

    test "a range with no sheet is refused before any request" do
      assert {:error, %Error{reason: :invalid_range}} =
               Sheetshow.read_rows("A1:B2", workbook("http://127.0.0.1:1"))
    end

    test "a workbook with no token says so, before any request" do
      workbook = Workbook.google("1AbC", base_url: "http://127.0.0.1:1")

      assert {:error, %Error{reason: :no_token}} = Sheetshow.read_rows("Costs", workbook)
    end

    test "what Google says when it refuses is what you get" do
      body = ~s({"error":{"code":400,"message":"Unable to parse range: nope"}})
      url = TestServer.start([{400, body}])

      assert {:error, %Error{reason: :http, details: %{status: 400}} = error} =
               Sheetshow.read_rows("nope!A1", workbook(url))

      assert error.message =~ "Unable to parse range"
    end

    test "read_rows! raises what read_rows returns" do
      workbook = Workbook.google("1AbC", base_url: "http://127.0.0.1:1")

      assert_raise Error, fn -> Sheetshow.read_rows!("Costs", workbook) end
    end
  end

  describe "read_rows/2 over several ranges" do
    defp batch(tables) do
      JSON.encode!(%{
        "spreadsheetId" => "1AbC",
        "valueRanges" => Enum.map(tables, &%{"range" => "x", "values" => &1})
      })
    end

    test "one table per range, in the order they were asked for" do
      url = TestServer.start([{200, batch([[["id"]], [["a"], ["b"]]])}])

      assert {:ok, [first, second]} =
               Sheetshow.read_rows(["log!A1:A1", "log!A2:A"], workbook(url))

      assert first == [["id"]]
      assert second == [["a"], ["b"]]

      assert_receive {:request, request}
      assert request.path == "/v4/spreadsheets/1AbC/values:batchGet"

      # A map would keep only the last of a repeated parameter; the wire carries
      # both, in order.
      assert Enum.filter(request.params, &(elem(&1, 0) == "ranges")) == [
               {"ranges", "log!A1"},
               {"ranges", "log!A2:A"}
             ]

      assert request.query["valueRenderOption"] == "UNFORMATTED_VALUE"
    end

    test "a range Google had nothing for is an empty table, not a missing one" do
      url = TestServer.start([{200, ~s({"valueRanges":[{"range":"x"},{"values":[["a"]]}]})}])

      assert {:ok, [[], [["a"]]]} =
               Sheetshow.read_rows(["log!A1:A1", "log!A2:A"], workbook(url))
    end

    test "no ranges asks nothing" do
      assert Sheetshow.read_rows([], workbook("http://127.0.0.1:1")) == {:ok, []}
    end

    test "one bad range is refused before any request" do
      assert {:error, %Error{reason: :invalid_range}} =
               Sheetshow.read_rows(["log!A1:A1", "A2:A"], workbook("http://127.0.0.1:1"))
    end
  end

  describe "Log.read/3" do
    defp log, do: Log.new("expenses", item: :string, cost: :decimal)

    test "reads the whole tab and folds to what the log says now" do
      rows = [
        ["id", "deleted", "item", "cost"],
        ["a", nil, "Rent", "1000.00"],
        ["b", nil, "Food", "400.00"],
        ["a", nil, "Rent", "1100.00"],
        ["b", true, nil, nil]
      ]

      url = TestServer.start([{200, answer(rows, "expenses")}])

      assert {:ok, events} = Log.read(log(), workbook(url))
      assert length(events) == 4
      assert Log.fold(events) |> Enum.map(& &1.record) == [%{item: "Rent", cost: "1100.00"}]

      assert_receive {:request, request}
      # The whole-sheet name is quoted, so Google reads the tab and not a
      # same-named range that would otherwise take precedence.
      assert request.path == "/v4/spreadsheets/1AbC/values/'expenses'"
    end

    test "carries :strict through to the decoding" do
      rows = [["id", "deleted", "item", "cost"], ["a", nil, "Rent", "free"]]
      url = TestServer.start([{200, answer(rows, "expenses")}, {200, answer(rows, "expenses")}])

      assert {:ok, [_event]} = Log.read(log(), workbook(url))
      assert {:error, %Error{reason: :cast}} = Log.read(log(), workbook(url), strict: true)
    end

    test "a tab with nothing on it is not a log, and says so" do
      url = TestServer.start([{200, ~s({"range":"expenses","majorDimension":"ROWS"})}])

      assert {:error, %Error{reason: :missing_header, details: %{sheet: "expenses"}}} =
               Log.read(log(), workbook(url))
    end

    test "an option nobody knows is a mistake worth raising on" do
      assert_raise ArgumentError, ~r/unknown keys \[:stict\]/, fn ->
        Log.decode([["id", "deleted", "item", "cost"]], log(), stict: true)
      end
    end

    test "read! raises what read returns" do
      url = TestServer.start([{404, ~s({"error":{"message":"nope"}})}])

      assert_raise Error, fn -> Log.read!(log(), workbook(url)) end
    end
  end

  describe "Log.read/3 after a cursor" do
    @header ["id", "deleted", "item", "cost"]

    defp cursor do
      %Log.Event{
        id: "b",
        row: 2,
        record: %{item: "Food", cost: "400.00"},
        deleted: false,
        errors: %{}
      }
    end

    defp tail(rows) do
      JSON.encode!(%{
        "valueRanges" => [
          %{"range" => "expenses!A1:D1", "values" => [@header]},
          %{"range" => "expenses!A3:D", "values" => rows}
        ]
      })
    end

    test "asks for the header and the rows from the cursor down, in one request" do
      url = TestServer.start([{200, tail([["b", "", "Food", "400.00"]])}])

      assert {:ok, []} = Log.read(log(), workbook(url), after: cursor())

      assert_receive {:request, request}
      assert request.path == "/v4/spreadsheets/1AbC/values:batchGet"

      assert Enum.filter(request.params, &(elem(&1, 0) == "ranges")) == [
               {"ranges", "expenses!1:1"},
               {"ranges", "expenses!A3:D"}
             ]
    end

    test "gives back what was appended after the cursor, numbered from where it sits" do
      rows = [
        ["b", "", "Food", "400.00"],
        ["c", "", "Fuel", "50.00"],
        ["b", true, "Food", "400.00"]
      ]

      url = TestServer.start([{200, tail(rows)}])

      assert {:ok, [fuel, gone]} = Log.read(log(), workbook(url), after: cursor())
      assert {fuel.id, fuel.row, fuel.record} == {"c", 3, %{item: "Fuel", cost: "50.00"}}
      assert {gone.id, gone.row, gone.deleted} == {"b", 4, true}
    end

    test "refuses when the cursor's row no longer holds the cursor" do
      url =
        TestServer.start([{200, tail([["x", "", "Other", "1.00"], ["c", "", "Fuel", "2.00"]])}])

      assert {:error, %Error{reason: :moved, details: details} = error} =
               Log.read(log(), workbook(url), after: cursor())

      assert details.row == 2
      assert details.expected == cursor()
      assert details.found.id == "x"
      assert Exception.message(error) =~ "read the log whole"
    end

    test "refuses when the cursor's row has been emptied" do
      url = TestServer.start([{200, tail([])}])

      assert {:error, %Error{reason: :moved, details: %{found: nil}}} =
               Log.read(log(), workbook(url), after: cursor())
    end

    test "a row identical to the cursor can stand in for it, and folding it changes nothing" do
      rows = [["b", "", "Food", "400.00"], ["b", "", "Food", "400.00"]]
      url = TestServer.start([{200, tail(rows)}])

      assert {:ok, [again]} = Log.read(log(), workbook(url), after: cursor())
      assert again.record == cursor().record

      assert Log.fold([cursor(), again]) |> Enum.map(& &1.record) == [cursor().record]
    end

    test "an event that never came from a read cannot be a cursor" do
      event = Log.Event.new(%{item: "Food"}, id: "b")

      assert_raise ArgumentError, ~r/knows the row it sits on/, fn ->
        Log.read(log(), workbook("http://127.0.0.1:1"), after: event)
      end
    end

    test "an option nobody knows is a mistake worth raising on" do
      assert_raise ArgumentError, ~r/unknown keys \[:since\]/, fn ->
        Log.read(log(), workbook("http://127.0.0.1:1"), since: cursor())
      end
    end
  end
end
