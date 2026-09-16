defmodule Sheetshow.A1 do
  @moduledoc """
  A1 notation: the `'Q1 costs'!B4:C9` strings Google Sheets speaks.

  Sheetshow rows and columns are 0-indexed. A1 rows are 1-indexed and A1
  columns are bijective base-26 letters (`A`, `Z`, `AA`). This module holds the
  conversions; `Sheetshow.Coord` and `Sheetshow.Range` parse and print with them.

  A sheet name is quoted when it could be mistaken for a cell reference or
  contains anything but letters, digits and underscores, with `'` doubled
  inside quotes, as Sheets does.
  """

  alias Sheetshow.Error

  @plain_sheet ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  # A cell (letters and digits) or two endpoints around a colon. Letters alone
  # cannot be a reference, so `log` or `A` on their own name a sheet.
  @ref_like ~r/^(\$?[A-Za-z]{1,3}\$?[0-9]+|\$?[A-Za-z]{0,3}\$?[0-9]*:\$?[A-Za-z]{0,3}\$?[0-9]*)$/
  @ref ~r/^\$?([A-Za-z]{1,3})?\$?([1-9][0-9]*)?$/

  @doc """
  0-indexed column to letters.

      iex> Sheetshow.A1.col_to_letters(0)
      "A"
      iex> Sheetshow.A1.col_to_letters(27)
      "AB"
  """
  @spec col_to_letters(non_neg_integer()) :: String.t()
  def col_to_letters(col) when is_integer(col) and col >= 0, do: letters(col, "")

  defp letters(col, acc) do
    acc = <<?A + rem(col, 26), acc::binary>>

    case div(col, 26) - 1 do
      n when n < 0 -> acc
      n -> letters(n, acc)
    end
  end

  @doc """
  Letters to 0-indexed column. Case-insensitive. Raises `ArgumentError` on
  anything but letters.

      iex> Sheetshow.A1.letters_to_col("ab")
      27
  """
  @spec letters_to_col(String.t()) :: non_neg_integer()
  def letters_to_col(letters) when is_binary(letters) do
    if letters == "" or not Regex.match?(~r/^[A-Za-z]+$/, letters) do
      raise ArgumentError, "expected column letters, got: #{inspect(letters)}"
    end

    letters
    |> String.upcase()
    |> String.to_charlist()
    |> Enum.reduce(0, fn c, acc -> acc * 26 + (c - ?A + 1) end)
    |> Kernel.-(1)
  end

  @doc """
  Quotes a sheet name when A1 notation needs it.

      iex> Sheetshow.A1.quote_sheet("Costs")
      "Costs"
      iex> Sheetshow.A1.quote_sheet("Q1 costs")
      "'Q1 costs'"
      iex> Sheetshow.A1.quote_sheet("Q1's")
      "'Q1''s'"
      iex> Sheetshow.A1.quote_sheet("Tab1")
      "'Tab1'"
  """
  @spec quote_sheet(String.t()) :: String.t()
  def quote_sheet(name) when is_binary(name) do
    if Regex.match?(@plain_sheet, name) and not Regex.match?(@ref_like, name) do
      name
    else
      "'" <> String.replace(name, "'", "''") <> "'"
    end
  end

  @doc """
  Splits an A1 string into `{sheet, rest}`. The sheet is `nil` when there is
  no sheet part; the rest is `nil` when a quoted name stands alone.

      iex> Sheetshow.A1.split_sheet("'Q1 costs'!A1:B2")
      {:ok, {"Q1 costs", "A1:B2"}}
      iex> Sheetshow.A1.split_sheet("Costs!A1")
      {:ok, {"Costs", "A1"}}
      iex> Sheetshow.A1.split_sheet("A1")
      {:ok, {nil, "A1"}}
      iex> Sheetshow.A1.split_sheet("'Costs'")
      {:ok, {"Costs", nil}}
  """
  @spec split_sheet(String.t()) ::
          {:ok, {String.t() | nil, String.t() | nil}} | {:error, Error.t()}
  def split_sheet("'" <> rest = a1), do: quoted(rest, "", a1)

  def split_sheet(a1) when is_binary(a1) do
    case String.split(a1, "!", parts: 2) do
      [rest] -> {:ok, {nil, rest}}
      ["", _] -> {:error, invalid(a1, "empty sheet name")}
      [sheet, rest] -> {:ok, {sheet, rest}}
    end
  end

  defp quoted("''" <> rest, acc, a1), do: quoted(rest, acc <> "'", a1)
  defp quoted("'!" <> rest, acc, a1) when acc != "", do: {:ok, {acc, rest}} |> reject_bang(a1)
  defp quoted("'", acc, _a1) when acc != "", do: {:ok, {acc, nil}}

  defp quoted(<<c::utf8, rest::binary>>, acc, a1) when c != ?',
    do: quoted(rest, <<acc::binary, c::utf8>>, a1)

  defp quoted(_, _acc, a1), do: {:error, invalid(a1, "unterminated quoted sheet name")}

  defp reject_bang({:ok, {_sheet, rest}} = ok, a1) do
    if String.contains?(rest, "!"), do: {:error, invalid(a1, "unexpected '!'")}, else: ok
  end

  @doc """
  Parses one endpoint of a reference into `{col, row}`, 0-indexed, where a
  missing part is `nil`. `$` anchors are accepted and dropped.

      iex> Sheetshow.A1.parse_ref("B4")
      {:ok, {1, 3}}
      iex> Sheetshow.A1.parse_ref("$C")
      {:ok, {2, nil}}
      iex> Sheetshow.A1.parse_ref("10")
      {:ok, {nil, 9}}
      iex> Sheetshow.A1.parse_ref("A0")
      :error
  """
  @spec parse_ref(String.t()) ::
          {:ok, {non_neg_integer() | nil, non_neg_integer() | nil}} | :error
  def parse_ref(ref) when is_binary(ref) do
    case Regex.run(@ref, ref, capture: :all_but_first) do
      nil -> :error
      [] -> :error
      [""] -> :error
      [letters] -> {:ok, {letters_to_col(letters), nil}}
      ["", digits] -> {:ok, {nil, String.to_integer(digits) - 1}}
      [letters, digits] -> {:ok, {letters_to_col(letters), String.to_integer(digits) - 1}}
    end
  end

  @doc """
  Whether a bare string reads as a cell or range reference rather than a sheet
  name. Sheet names for which this is true need quoting, as in Sheets itself.

      iex> Sheetshow.A1.ref_like?("Tab1")
      true
      iex> Sheetshow.A1.ref_like?("A:A")
      true
      iex> Sheetshow.A1.ref_like?("log")
      false
  """
  @spec ref_like?(String.t()) :: boolean()
  def ref_like?(str) when is_binary(str), do: str != "" and Regex.match?(@ref_like, str)

  @doc false
  def invalid(a1, why), do: Error.new(:invalid_a1, "cannot parse #{inspect(a1)}: #{why}", a1: a1)
end
