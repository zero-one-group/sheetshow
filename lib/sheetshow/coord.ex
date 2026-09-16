defmodule Sheetshow.Coord do
  @moduledoc """
  Where a cell is: a 0-indexed `row` and `col`, and optionally the `sheet`
  (tab) it belongs to.

      iex> Sheetshow.Coord.new(3, 1, "Costs")
      %Sheetshow.Coord{row: 3, col: 1, sheet: "Costs"}
      iex> Sheetshow.Coord.new(3, 1, "Costs") |> Sheetshow.Coord.to_a1()
      "Costs!B4"

  Coordinates sort row-major within a sheet, so `Enum.sort(coords, Sheetshow.Coord)`
  gives reading order.
  """

  alias Sheetshow.{A1, Error}

  @enforce_keys [:row, :col]
  defstruct [:row, :col, sheet: nil]

  @type t :: %__MODULE__{row: non_neg_integer(), col: non_neg_integer(), sheet: String.t() | nil}

  @doc """
  Builds a coordinate.

      iex> Sheetshow.Coord.new(0, 0)
      %Sheetshow.Coord{row: 0, col: 0, sheet: nil}
  """
  @spec new(non_neg_integer(), non_neg_integer(), String.t() | nil) :: t()
  def new(row, col, sheet \\ nil)
      when is_integer(row) and row >= 0 and is_integer(col) and col >= 0 and
             (is_binary(sheet) or is_nil(sheet)) do
    %__MODULE__{row: row, col: col, sheet: sheet}
  end

  @doc """
  Parses a single-cell A1 reference.

      iex> Sheetshow.Coord.from_a1("B4")
      {:ok, %Sheetshow.Coord{row: 3, col: 1, sheet: nil}}
      iex> Sheetshow.Coord.from_a1("'Q1 costs'!$B$4")
      {:ok, %Sheetshow.Coord{row: 3, col: 1, sheet: "Q1 costs"}}
      iex> {:error, %Sheetshow.Error{reason: :invalid_a1}} = Sheetshow.Coord.from_a1("A1:B2")
  """
  @spec from_a1(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_a1(a1) when is_binary(a1) do
    with {:ok, {sheet, ref}} when is_binary(ref) <- A1.split_sheet(a1),
         {:ok, {col, row}} when is_integer(col) and is_integer(row) <- A1.parse_ref(ref) do
      {:ok, new(row, col, sheet)}
    else
      {:error, %Error{}} = error -> error
      _ -> {:error, A1.invalid(a1, "expected a single cell such as B4 or Costs!B4")}
    end
  end

  @doc "Same as `from_a1/1`, raising on failure."
  @spec from_a1!(String.t()) :: t()
  def from_a1!(a1), do: a1 |> from_a1() |> Error.unwrap!()

  @doc """
  Prints as A1, with the sheet when there is one.

      iex> Sheetshow.Coord.to_a1(%Sheetshow.Coord{row: 0, col: 26})
      "AA1"
      iex> Sheetshow.Coord.to_a1(%Sheetshow.Coord{row: 0, col: 0, sheet: "Q1 costs"})
      "'Q1 costs'!A1"
  """
  @spec to_a1(t()) :: String.t()
  def to_a1(%__MODULE__{row: row, col: col, sheet: sheet}) do
    prefix = if sheet, do: A1.quote_sheet(sheet) <> "!", else: ""
    prefix <> A1.col_to_letters(col) <> Integer.to_string(row + 1)
  end

  @doc """
  Moves a coordinate by `rows` down and `cols` right. Negative deltas move up
  and left; moving off the sheet raises `ArgumentError`.

      iex> Sheetshow.Coord.new(1, 1) |> Sheetshow.Coord.shift(2, -1)
      %Sheetshow.Coord{row: 3, col: 0, sheet: nil}
  """
  @spec shift(t(), integer(), integer()) :: t()
  def shift(%__MODULE__{row: row, col: col} = coord, rows, cols)
      when is_integer(rows) and is_integer(cols) do
    if row + rows < 0 or col + cols < 0 do
      raise ArgumentError, "shifting #{to_a1(coord)} by (#{rows}, #{cols}) leaves the sheet"
    end

    %{coord | row: row + rows, col: col + cols}
  end

  @doc """
  Row-major order within a sheet; sheets order by name, `nil` first.
  For `Enum.sort/2` and friends.

      iex> coords = [Sheetshow.Coord.new(1, 0), Sheetshow.Coord.new(0, 5), Sheetshow.Coord.new(0, 2)]
      iex> Enum.sort(coords, Sheetshow.Coord) |> Enum.map(&Sheetshow.Coord.to_a1/1)
      ["C1", "F1", "A2"]
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = a, %__MODULE__{} = b) do
    case {{a.sheet, a.row, a.col}, {b.sheet, b.row, b.col}} do
      {x, x} -> :eq
      {x, y} when x < y -> :lt
      _ -> :gt
    end
  end
end
