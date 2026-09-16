defmodule Sheetshow.RunsTest do
  use ExUnit.Case, async: true

  doctest Sheetshow.Runs

  alias Sheetshow.Runs

  test "a run ends where the index skips or the tag changes" do
    items = [{0, :a}, {1, :a}, {2, :b}, {4, :b}, {5, :b}]

    assert Runs.consecutive(items, &elem(&1, 0), &elem(&1, 1)) ==
             [[{0, :a}, {1, :a}], [{2, :b}], [{4, :b}, {5, :b}]]
  end

  test "one item is one run, and a repeated index is a new run rather than a gap" do
    assert Runs.consecutive([7], & &1) == [[7]]
    assert Runs.consecutive([1, 1, 2], & &1) == [[1], [1, 2]]
  end

  test "ranges sort, drop repeats and ascend" do
    assert Runs.ranges([9, 2, 1, 2, 3]) == [1..3, 9..9]
    assert Runs.ranges([]) == []
  end
end
