defmodule Sheetshow.ResultTest do
  use ExUnit.Case, async: true

  doctest Sheetshow.Result

  alias Sheetshow.Result

  test "map stops at the first error and never calls the function again" do
    seen = :counters.new(1, [])

    step = fn
      3 -> {:error, :three}
      n -> :counters.add(seen, 1, 1) && {:ok, n}
    end

    assert Result.map([1, 2, 3, 4], step) == {:error, :three}
    assert :counters.get(seen, 1) == 2
  end

  test "map and reduce of nothing is nothing" do
    assert Result.map([], fn _ -> {:error, :never} end) == {:ok, []}
    assert Result.reduce([], :acc, fn _, _ -> {:error, :never} end) == {:ok, :acc}
  end

  test "reduce hands each step the accumulator the last one left" do
    assert Result.reduce([1, 2, 3], [], &{:ok, [&1 | &2]}) == {:ok, [3, 2, 1]}

    assert Result.reduce([1, 2, 3], [], fn
             2, _ -> {:error, :two}
             n, acc -> {:ok, [n | acc]}
           end) == {:error, :two}
  end
end
