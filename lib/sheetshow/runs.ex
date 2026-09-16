defmodule Sheetshow.Runs do
  @moduledoc false
  # Neighbouring things travel together: cells in one `PutCells`, rows in one
  # `DeleteRows`, columns of one width in one `<col>`. This is the one place
  # that decides what "neighbouring" means.

  @doc """
  Splits an ascending list where the index skips, or where the tag changes.
  `index` gives each item's position; `tag` (optional) gives what has to stay
  the same for two neighbours to share a run.

      iex> Sheetshow.Runs.consecutive([1, 2, 4, 5, 6, 9], & &1)
      [[1, 2], [4, 5, 6], [9]]
      iex> Sheetshow.Runs.consecutive([{0, :a}, {1, :a}, {2, :b}], &elem(&1, 0), &elem(&1, 1))
      [[{0, :a}, {1, :a}], [{2, :b}]]
      iex> Sheetshow.Runs.consecutive([], & &1)
      []
  """
  @spec consecutive([item], (item -> integer()), (item -> term())) :: [[item]] when item: term()
  def consecutive(items, index, tag \\ fn _ -> nil end)
      when is_list(items) and is_function(index, 1) and is_function(tag, 1) do
    items
    |> Enum.chunk_while(
      [],
      fn item, run ->
        case run do
          [previous | _] ->
            if index.(item) == index.(previous) + 1 and tag.(item) == tag.(previous),
              do: {:cont, [item | run]},
              else: {:cont, Enum.reverse(run), [item]}

          [] ->
            {:cont, [item]}
        end
      end,
      fn
        [] -> {:cont, []}
        run -> {:cont, Enum.reverse(run), []}
      end
    )
  end

  @doc """
  The inclusive range each run of integers covers, ascending.

      iex> Sheetshow.Runs.ranges([5, 1, 2, 3, 9, 5])
      [1..3, 5..5, 9..9]
  """
  @spec ranges([integer()]) :: [Range.t()]
  def ranges(integers) when is_list(integers) do
    integers
    |> Enum.sort()
    |> Enum.dedup()
    |> consecutive(& &1)
    |> Enum.map(&(hd(&1)..List.last(&1)))
  end
end
