defmodule Sheetshow.Result do
  @moduledoc false
  # Walking a list where any step may answer `{:error, _}`, and stopping at the
  # first one that does. Every backend, planner and codec has a loop like this;
  # here they are once.

  @type result(value) :: {:ok, value} | {:error, term()}

  @doc """
  `Enum.map/2` where `fun` answers `{:ok, value} | {:error, reason}`: the
  mapped list in order, or the first error.

      iex> Sheetshow.Result.map([1, 2], &{:ok, &1 * 2})
      {:ok, [2, 4]}
      iex> Sheetshow.Result.map([1, 2], fn _ -> {:error, :no} end)
      {:error, :no}
  """
  @spec map(Enumerable.t(), (term() -> result(value))) :: result([value]) when value: term()
  def map(enumerable, fun) when is_function(fun, 1) do
    with {:ok, reversed} <-
           reduce(enumerable, [], fn item, acc ->
             with {:ok, value} <- fun.(item), do: {:ok, [value | acc]}
           end) do
      {:ok, Enum.reverse(reversed)}
    end
  end

  @doc """
  `Enum.reduce/3` where `fun` answers `{:ok, acc} | {:error, reason}`: the
  final accumulator, or the first error.

      iex> Sheetshow.Result.reduce([1, 2, 3], 0, &{:ok, &1 + &2})
      {:ok, 6}
  """
  @spec reduce(Enumerable.t(), acc, (term(), acc -> result(acc))) :: result(acc) when acc: term()
  def reduce(enumerable, acc, fun) when is_function(fun, 2) do
    Enum.reduce_while(enumerable, {:ok, acc}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, _} = ok -> {:cont, ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
