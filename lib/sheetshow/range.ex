defmodule Sheetshow.Range do
  @moduledoc """
  A rectangle of cells on one sheet: `Costs!A2:C10`, a whole column, a whole
  sheet.

  Bounds are 0-indexed and inclusive. An `end_row` or `end_col` of `nil` is
  unbounded, which is how Sheets spells "to the end": `A:A` is
  `%Range{start_col: 0, end_col: 0, end_row: nil}` and `A2:F` is rows from 1
  with columns 0 to 5. The struct literal is the constructor for those; `new/3`
  takes Elixir ranges for the bounded case.

      iex> Sheetshow.Range.new("Costs", 1..9, 0..2) |> Sheetshow.Range.to_a1()
      "Costs!A2:C10"
      iex> Sheetshow.Range.to_a1(%Sheetshow.Range{sheet: "log", start_row: 10, end_col: 5})
      "log!A11:F"

  Unquoted names that look like references (`Tab1`) are read as references,
  exactly as Sheets does; quote them (`'Tab1'`) to mean the sheet.
  """

  alias Sheetshow.{A1, Coord, Error}

  defstruct sheet: nil, start_row: 0, start_col: 0, end_row: nil, end_col: nil

  @type bound :: non_neg_integer() | nil
  @type t :: %__MODULE__{
          sheet: String.t() | nil,
          start_row: non_neg_integer(),
          start_col: non_neg_integer(),
          end_row: bound(),
          end_col: bound()
        }

  @doc """
  A bounded range from Elixir ranges of rows and columns.

      iex> Sheetshow.Range.new(nil, 0..0, 0..3)
      %Sheetshow.Range{sheet: nil, start_row: 0, start_col: 0, end_row: 0, end_col: 3}
  """
  @spec new(String.t() | nil, Range.t(), Range.t()) :: t()
  def new(sheet, r1..r2//1, c1..c2//1)
      when (is_binary(sheet) or is_nil(sheet)) and r1 >= 0 and r2 >= r1 and c1 >= 0 and
             c2 >= c1 do
    %__MODULE__{sheet: sheet, start_row: r1, start_col: c1, end_row: r2, end_col: c2}
  end

  @doc """
  Parses an A1 range. A bare quoted or non-reference-like name is the whole
  sheet; reversed corners are normalised.

      iex> Sheetshow.Range.from_a1("Costs!C3:A1")
      {:ok, %Sheetshow.Range{sheet: "Costs", start_row: 0, start_col: 0, end_row: 2, end_col: 2}}
      iex> Sheetshow.Range.from_a1("B:B")
      {:ok, %Sheetshow.Range{sheet: nil, start_row: 0, start_col: 1, end_row: nil, end_col: 1}}
      iex> Sheetshow.Range.from_a1("2:3")
      {:ok, %Sheetshow.Range{sheet: nil, start_row: 1, start_col: 0, end_row: 2, end_col: nil}}
      iex> Sheetshow.Range.from_a1("Costs")
      {:ok, %Sheetshow.Range{sheet: "Costs", start_row: 0, start_col: 0, end_row: nil, end_col: nil}}
      iex> {:error, %Sheetshow.Error{reason: :invalid_a1}} = Sheetshow.Range.from_a1("A0")
  """
  @spec from_a1(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_a1(a1) when is_binary(a1) do
    with {:ok, {sheet, rest}} <- A1.split_sheet(a1),
         {:ok, range} <- parse_rest(sheet, rest, a1) do
      {:ok, range}
    end
  end

  @doc "Same as `from_a1/1`, raising on failure."
  @spec from_a1!(String.t()) :: t()
  def from_a1!(a1), do: a1 |> from_a1() |> Error.unwrap!()

  @doc false
  # A read needs a sheet, because a spreadsheet has more than one.
  @spec on_sheet(t()) :: {:ok, t()} | {:error, Error.t()}
  def on_sheet(%__MODULE__{sheet: nil} = range) do
    {:error,
     Error.new(:invalid_range, "reading needs a sheet, got #{inspect(range)}", range: range)}
  end

  def on_sheet(%__MODULE__{} = range), do: {:ok, range}

  # A quoted name on its own is the whole sheet; so is an unquoted one that
  # could not be a reference.
  defp parse_rest(sheet, nil, _a1), do: {:ok, %__MODULE__{sheet: sheet}}
  defp parse_rest(nil, "", a1), do: {:error, A1.invalid(a1, "empty")}
  defp parse_rest(_sheet, "", a1), do: {:error, A1.invalid(a1, "nothing after '!'")}

  defp parse_rest(nil, rest, a1) do
    cond do
      A1.ref_like?(rest) ->
        parse_refs(nil, rest, a1)

      String.contains?(rest, ":") ->
        {:error, A1.invalid(a1, "not a reference; quote sheet names")}

      true ->
        {:ok, %__MODULE__{sheet: rest}}
    end
  end

  defp parse_rest(sheet, rest, a1), do: parse_refs(sheet, rest, a1)

  defp parse_refs(sheet, rest, a1) do
    case String.split(rest, ":") do
      [ref] ->
        case A1.parse_ref(ref) do
          {:ok, {col, row}} when is_integer(col) and is_integer(row) ->
            {:ok,
             %__MODULE__{sheet: sheet, start_row: row, start_col: col, end_row: row, end_col: col}}

          _ ->
            {:error, A1.invalid(a1, "a single reference must name a cell, such as B4")}
        end

      [from, to] ->
        with {:ok, {c1, r1}} <- A1.parse_ref(from),
             {:ok, {c2, r2}} <- A1.parse_ref(to),
             {:ok, {r1, r2}} <- axis(r1, r2),
             {:ok, {c1, c2}} <- axis(c1, c2) do
          {:ok,
           %__MODULE__{
             sheet: sheet,
             start_row: r1 || 0,
             start_col: c1 || 0,
             end_row: r2,
             end_col: c2
           }}
        else
          _ -> {:error, A1.invalid(a1, "expected a range such as A1:C3, A:A or A2:F")}
        end

      _ ->
        {:error, A1.invalid(a1, "too many ':'")}
    end
  end

  # One axis of a two-endpoint range: both bounds, neither, or open at the end.
  defp axis(a, b) when is_integer(a) and is_integer(b), do: {:ok, {min(a, b), max(a, b)}}
  defp axis(a, nil), do: {:ok, {a, nil}}
  defp axis(nil, _b), do: :error

  @doc """
  Prints as A1. A single cell prints as one reference; a whole sheet as its
  name, which it must have.

      iex> Sheetshow.Range.to_a1(%Sheetshow.Range{start_row: 3, start_col: 1, end_row: 3, end_col: 1})
      "B4"
      iex> Sheetshow.Range.to_a1(%Sheetshow.Range{sheet: "Costs", end_col: 2})
      "Costs!A:C"
      iex> Sheetshow.Range.to_a1(%Sheetshow.Range{sheet: "Q1 costs"})
      "'Q1 costs'"

  `quote_sheet: true` quotes a whole-sheet name even when it would otherwise be
  bare. Google's values endpoint reads a bare whole-sheet name as a named range
  of the same name in preference to the sheet, so the read path passes this.

      iex> Sheetshow.Range.to_a1(%Sheetshow.Range{sheet: "Costs"}, quote_sheet: true)
      "'Costs'"
  """
  @spec to_a1(t(), keyword()) :: String.t()
  def to_a1(%__MODULE__{sheet: sheet} = range, opts \\ []) do
    refs = refs(range)

    prefix =
      cond do
        is_nil(sheet) -> nil
        # Only a whole-sheet name is ambiguous; `Costs!A1:B2` already reads as
        # the sheet because a named range carries no `!`.
        is_nil(refs) and Keyword.get(opts, :quote_sheet, false) -> A1.quote_sheet(sheet, true)
        true -> A1.quote_sheet(sheet)
      end

    case {prefix, refs} do
      {nil, nil} -> raise ArgumentError, "a whole-sheet range needs a sheet name"
      {prefix, nil} -> prefix
      {nil, refs} -> refs
      {prefix, refs} -> prefix <> "!" <> refs
    end
  end

  defp refs(%{start_row: 0, start_col: 0, end_row: nil, end_col: nil}), do: nil

  defp refs(%{start_row: r, start_col: c, end_row: r, end_col: c}), do: ref(c, r)

  defp refs(%{start_row: r1, start_col: c1, end_row: r2, end_col: c2}) do
    # Whole columns print as A:C and whole rows as 2:3; anything else keeps its
    # start corner in full.
    from =
      cond do
        r1 == 0 and r2 == nil -> ref(c1, nil)
        c1 == 0 and c2 == nil -> ref(nil, r1)
        true -> ref(c1, r1)
      end

    if r2 == nil and c2 == nil do
      raise ArgumentError, "A1 notation cannot express an open range starting at #{from}"
    end

    from <> ":" <> ref(c2, r2)
  end

  defp ref(col, row) do
    letters = if col, do: A1.col_to_letters(col), else: ""
    digits = if row, do: Integer.to_string(row + 1), else: ""
    letters <> digits
  end

  @doc """
  The smallest range holding every coordinate or cell given. They must share a
  sheet; the list must not be empty.

      iex> coords = [Sheetshow.Coord.new(4, 1, "Costs"), Sheetshow.Coord.new(0, 3, "Costs")]
      iex> Sheetshow.Range.bounding(coords) |> Sheetshow.Range.to_a1()
      "Costs!B1:D5"
  """
  @spec bounding([Coord.t() | %{coord: Coord.t()}]) :: t()
  def bounding([_ | _] = items) do
    coords = Enum.map(items, &coord_of/1)

    case Enum.uniq(Enum.map(coords, & &1.sheet)) do
      [sheet] ->
        rows = Enum.map(coords, & &1.row)
        cols = Enum.map(coords, & &1.col)
        new(sheet, Enum.min(rows)..Enum.max(rows), Enum.min(cols)..Enum.max(cols))

      sheets ->
        raise ArgumentError, "bounding needs one sheet, got #{inspect(sheets)}"
    end
  end

  defp coord_of(%Coord{} = coord), do: coord
  defp coord_of(%{coord: %Coord{} = coord}), do: coord

  @doc """
  Whether the coordinate lies inside the range. The sheets must match, and a
  `nil` sheet matches only `nil`.

      iex> range = Sheetshow.Range.from_a1!("Costs!A2:C")
      iex> Sheetshow.Range.contains?(range, Sheetshow.Coord.new(100, 2, "Costs"))
      true
      iex> Sheetshow.Range.contains?(range, Sheetshow.Coord.new(0, 0, "Costs"))
      false
  """
  @spec contains?(t(), Coord.t()) :: boolean()
  def contains?(%__MODULE__{} = range, %Coord{} = coord) do
    range.sheet == coord.sheet and
      coord.row >= range.start_row and coord.col >= range.start_col and
      (range.end_row == nil or coord.row <= range.end_row) and
      (range.end_col == nil or coord.col <= range.end_col)
  end

  @doc """
  Whether both ends are known.

      iex> Sheetshow.Range.bounded?(Sheetshow.Range.from_a1!("A1:B2"))
      true
      iex> Sheetshow.Range.bounded?(Sheetshow.Range.from_a1!("A:B"))
      false
  """
  @spec bounded?(t()) :: boolean()
  def bounded?(%__MODULE__{end_row: r, end_col: c}), do: is_integer(r) and is_integer(c)
end
