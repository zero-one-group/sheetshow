defmodule Sheetshow.PropertiesTest do
  use ExUnit.Case, async: true

  # Round trips over generated input, where the example tests pin one case
  # each. No property-testing library, so the generator is `:rand` with a fixed
  # seed: the same two hundred cases every run, and a failure names its input.

  alias Sheetshow.{Cell, Coord, Log, Memory, Range, Value}
  alias Sheetshow.Log.Event

  @cases 200

  setup do
    :rand.seed(:exsss, {17, 9, 2026})
    :ok
  end

  defp pick(list), do: Enum.random(list)

  describe "A1 notation" do
    defp sheet_name do
      pick([nil, "Costs", "Q1 costs", "Q1's", "Tab1", "2024", "log", "a!b", "'", "Sheet1"])
    end

    defp range do
      sheet = sheet_name()
      r1 = :rand.uniform(1000) - 1
      c1 = :rand.uniform(80) - 1

      case pick([:cell, :box, :columns, :rows_open, :whole]) do
        :cell ->
          %Range{sheet: sheet, start_row: r1, start_col: c1, end_row: r1, end_col: c1}

        :box ->
          %Range{
            sheet: sheet,
            start_row: r1,
            start_col: c1,
            end_row: r1 + :rand.uniform(50) - 1,
            end_col: c1 + :rand.uniform(20) - 1
          }

        # Whole columns start at row 0; rows open at the bottom keep their
        # columns bounded, which is what the cursor read does.
        :columns ->
          %Range{sheet: sheet, start_row: 0, start_col: c1, end_row: nil, end_col: c1 + 2}

        :rows_open ->
          %Range{sheet: sheet, start_row: r1, start_col: c1, end_row: nil, end_col: c1}

        :whole ->
          %Range{sheet: sheet || "Costs"}
      end
    end

    test "a range prints as A1 and parses back to itself" do
      for _ <- 1..@cases do
        range = range()
        a1 = Range.to_a1(range)
        assert {:ok, ^range} = Range.from_a1(a1), "#{inspect(range)} printed as #{inspect(a1)}"
      end
    end

    test "a coordinate does too, on every sheet name" do
      for _ <- 1..@cases do
        coord = Coord.new(:rand.uniform(5000) - 1, :rand.uniform(500) - 1, sheet_name())
        assert {:ok, ^coord} = Coord.from_a1(Coord.to_a1(coord))
      end
    end

    test "bounding a range's corners gives the range back" do
      for _ <- 1..@cases do
        %Range{end_row: r2, end_col: c2} = range = range()

        if is_integer(r2) and is_integer(c2) do
          corners = [
            Coord.new(range.start_row, range.start_col, range.sheet),
            Coord.new(r2, c2, range.sheet)
          ]

          assert Range.bounding(corners) == range
        end
      end
    end
  end

  describe "serial numbers" do
    defp naive do
      days = :rand.uniform(80_000) - 40_000
      ms = :rand.uniform(86_400_000) - 1

      ~N[1899-12-30 00:00:00]
      |> NaiveDateTime.add(days, :day)
      |> NaiveDateTime.add(ms, :millisecond)
    end

    test "a datetime to the millisecond survives the trip, anywhere in a few centuries" do
      for _ <- 1..@cases do
        ndt = naive()
        back = ndt |> Value.to_serial() |> Value.from_serial(:datetime)
        assert NaiveDateTime.compare(back, ndt) == :eq, "#{ndt} came back as #{back}"
      end
    end

    test "its date and its time each survive on their own" do
      for _ <- 1..@cases do
        ndt = naive()
        date = NaiveDateTime.to_date(ndt)
        time = NaiveDateTime.to_time(ndt)

        assert date |> Value.to_serial() |> Value.from_serial(:date) == date
        assert Time.compare(time |> Value.to_serial() |> Value.from_serial(:time), time) == :eq
      end
    end

    test "the date of a datetime serial is the date, whatever the time of day" do
      for _ <- 1..@cases do
        ndt = naive()
        assert ndt |> Value.to_serial() |> Value.from_serial(:date) == NaiveDateTime.to_date(ndt)
      end
    end
  end

  describe "a plan" do
    defp cells do
      sheet = pick(["Costs", "log"])

      for _ <- 1..(:rand.uniform(12) - 1)//1, uniq: true do
        Cell.new(
          Coord.new(:rand.uniform(6) - 1, :rand.uniform(6) - 1, sheet),
          pick([1, 2.5, "x", true, ~D[2026-09-12], {:formula, "=1+1"}, nil]),
          pick([%{}, %{bold: true}, %{col_width: 90}])
        )
      end
    end

    # What the planner writes is what a read gives back: every cell that holds
    # something, once, the last one at a coordinate winning.
    test "writes exactly the cells that hold something, read back through the memory" do
      for _ <- 1..@cases do
        cells = cells()

        sheet =
          case cells do
            [] -> "Costs"
            [%Cell{coord: %Coord{sheet: sheet}} | _] -> sheet
          end

        plan = Sheetshow.plan!(cells, existing_sheets: [])
        memory = Memory.run!(plan, Memory.new())

        expected =
          cells
          |> Map.new(&{{&1.coord.row, &1.coord.col}, &1})
          |> Map.values()
          |> Enum.map(fn cell ->
            Cell.with_number_format(%{cell | style: Map.delete(cell.style, :col_width)})
          end)
          |> Enum.reject(&(&1.value == nil and &1.style == %{}))
          |> Enum.sort_by(& &1.coord, Coord)

        read = if cells == [], do: [], else: Memory.read!(sheet, memory)
        assert read == expected, "planned #{inspect(cells)}"
      end
    end

    test "planning what was read back changes nothing: a plan is idempotent" do
      for _ <- 1..@cases do
        cells = cells()

        with [%Cell{coord: %Coord{sheet: sheet}} | _] <- cells do
          memory = Memory.run!(Sheetshow.plan!(cells, existing_sheets: []), Memory.new())
          read = Memory.read!(sheet, memory)
          again = Memory.run!(Sheetshow.plan!(read), memory)
          assert Memory.read!(sheet, again) == read
        end
      end
    end
  end

  describe "a log" do
    defp events do
      ids = Enum.map(1..(:rand.uniform(6) + 1), &"id#{&1}")

      for _ <- 1..(:rand.uniform(30) - 1)//1 do
        id = pick(ids)

        case :rand.uniform(4) do
          1 -> Event.delete(id)
          _ -> Event.new(%{n: :rand.uniform(100)}, id: id)
        end
      end
    end

    # The rule the incremental read rests on, over random histories. The one
    # documented exception, an id deleted and written again, is not generated:
    # a tombstone is the last thing that happens to its id.
    test "folding in batches is folding at once" do
      for _ <- 1..@cases do
        events = without_resurrections(events())
        {old, new} = Enum.split(events, :rand.uniform(length(events) + 1) - 1)

        assert Log.fold(Log.fold(old) ++ new) == Log.fold(old ++ new), inspect(events)
      end
    end

    test "the fold holds one event per live id, and never a tombstone" do
      for _ <- 1..@cases do
        events = events()
        folded = Log.fold(events)
        ids = Enum.map(folded, & &1.id)

        assert ids == Enum.uniq(ids)
        refute Enum.any?(folded, & &1.deleted)

        for event <- folded do
          last = events |> Enum.filter(&(&1.id == event.id)) |> List.last()
          assert last == event
        end
      end
    end

    defp without_resurrections(events) do
      dead = for %Event{deleted: true, id: id} <- events, into: MapSet.new(), do: id

      # Keep everything up to and including each dead id's tombstone, and drop
      # what was written to it after that.
      {kept, _} =
        Enum.reduce(events, {[], MapSet.new()}, fn event, {kept, buried} ->
          cond do
            MapSet.member?(buried, event.id) ->
              {kept, buried}

            event.deleted and MapSet.member?(dead, event.id) ->
              {[event | kept], MapSet.put(buried, event.id)}

            true ->
              {[event | kept], buried}
          end
        end)

      Enum.reverse(kept)
    end
  end
end
