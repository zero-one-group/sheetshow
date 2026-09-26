defmodule Sheetshow.Xlsx.Formula do
  @moduledoc false
  # Moving a formula's relative references, which is what a shared formula
  # asks a reader to do.
  #
  # Excel writes a column of filled-down formulas once: the top cell carries
  # the text (`<f t="shared" ref="B2:B9" si="0">A2*2</f>`) and every cell below
  # it carries only the pointer (`<f t="shared" si="0"/>`), meaning "the
  # formula above, shifted to here". Nothing else in the file says what those
  # cells hold, so reading them means working the shift out: a relative
  # reference moves with the cell, an anchored one (`$A$1`) stays put, and one
  # that would move off the sheet is `#REF!`. That is the rule Excel itself
  # applies when a formula is filled down or across (ECMA-376 part 1,
  # 18.17.2.2), and it is what LibreOffice and openpyxl do on reading too.

  alias Sheetshow.A1

  # A cell reference, a whole-column range or a whole-row range, outside a
  # string literal. Not preceded by a letter, digit, `_`, `.` or `$`, so `LOG10`
  # in `LOG10(A1)` and `24` in `1.5E24` are left alone, and not followed by one
  # or by `(`, so a function name that happens to look like a reference is too.
  # Nor followed by `!`, or by `:` and a name and `!`: that is a sheet's name
  # (`Q1!A1`, `Q1:Q4!A1`), which LibreOffice writes unquoted even when it looks
  # like a cell, and moving it pointed the formula at another sheet.
  @token ~r/
    (?<![A-Za-z0-9_.$])
    (?:
      (\$?)([A-Za-z]{1,3})(\$?)([0-9]+)(?![A-Za-z0-9_(!])(?!:[A-Za-z0-9_.$]+!)
      |
      (\$?)([A-Za-z]{1,3}):(\$?)([A-Za-z]{1,3})(?![A-Za-z0-9_(!])
      |
      (\$?)([0-9]+):(\$?)([0-9]+)(?![A-Za-z0-9_(!])
    )
  /x

  # The last column (XFD) and the last row there are: a reference moved past
  # either is off the sheet, which is `#REF!`, as it is moved past the first.
  @last_col 16_383
  @last_row 1_048_576

  @doc """
  The formula as it reads `rows` down and `cols` across from where it was
  written, without its leading `=`.

      iex> Sheetshow.Xlsx.Formula.translate("A1*2+$B$1", 3, 1)
      "B4*2+$B$1"
      iex> Sheetshow.Xlsx.Formula.translate(~s|SUM(A:A)&"A1"&'Q1 costs'!B2|, 0, 2)
      ~s|SUM(C:C)&"A1"&'Q1 costs'!D2|
      iex> Sheetshow.Xlsx.Formula.translate("A1", -1, 0)
      "#REF!"
      iex> Sheetshow.Xlsx.Formula.translate("Q1!A1+Table1[Q1]", 1, 0)
      "Q1!A2+Table1[Q1]"
  """
  @spec translate(String.t(), integer(), integer()) :: String.t()
  def translate(formula, 0, 0), do: formula

  def translate(formula, rows, cols) when is_binary(formula) do
    formula
    |> segments([], [])
    |> Enum.map_join(fn
      {:literal, text} -> text
      {:plain, text} -> shift(text, rows, cols)
    end)
  end

  # The formula cut into what may hold a reference and what may not: a string in
  # double quotes and a sheet name in single ones (each doubling its own quote
  # inside), and anything in square brackets, nested or not. A bracket is a
  # structured reference (`Table1[Q1]`, `Sales[[#This Row],[Q1]]`, `[@Q1]`), whose
  # contents are a table's column names, or an external workbook's index (`[1]`);
  # either way nothing in it is a cell to move.
  defp segments("", plain, acc), do: Enum.reverse(flush(plain, acc))

  defp segments(<<quote, _::binary>> = rest, plain, acc) when quote in [?", ?'] do
    {literal, rest} = quoted(rest, quote)
    segments(rest, [], [{:literal, literal} | flush(plain, acc)])
  end

  defp segments("[" <> _ = rest, plain, acc) do
    {literal, rest} = bracketed(rest, 0, [])
    segments(rest, [], [{:literal, literal} | flush(plain, acc)])
  end

  defp segments(<<char::utf8, rest::binary>>, plain, acc),
    do: segments(rest, [<<char::utf8>> | plain], acc)

  defp flush([], acc), do: acc
  defp flush(plain, acc), do: [{:plain, plain |> Enum.reverse() |> IO.iodata_to_binary()} | acc]

  # A quoted run up to its closing quote, a doubled quote being one quote inside
  # it; an unclosed one runs to the end.
  defp quoted(<<quote, rest::binary>>, quote), do: quoted_rest(rest, quote, [<<quote>>])

  defp quoted_rest(<<quote, quote, rest::binary>>, quote, acc),
    do: quoted_rest(rest, quote, [<<quote, quote>> | acc])

  defp quoted_rest(<<quote, rest::binary>>, quote, acc),
    do: {IO.iodata_to_binary(Enum.reverse([<<quote>> | acc])), rest}

  defp quoted_rest(<<char::utf8, rest::binary>>, quote, acc),
    do: quoted_rest(rest, quote, [<<char::utf8>> | acc])

  defp quoted_rest("", _quote, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), ""}

  # Brackets nest (`[[#This Row],[Q1]]`), and a `'` inside one escapes the
  # character after it, so `[Q1']']` is one bracket.
  defp bracketed("[" <> rest, depth, acc), do: bracketed(rest, depth + 1, ["[" | acc])

  defp bracketed("]" <> rest, 1, acc), do: {IO.iodata_to_binary(Enum.reverse(["]" | acc])), rest}
  defp bracketed("]" <> rest, depth, acc), do: bracketed(rest, depth - 1, ["]" | acc])

  defp bracketed(<<?', char::utf8, rest::binary>>, depth, acc),
    do: bracketed(rest, depth, [<<?', char::utf8>> | acc])

  defp bracketed(<<char::utf8, rest::binary>>, depth, acc),
    do: bracketed(rest, depth, [<<char::utf8>> | acc])

  defp bracketed("", _depth, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), ""}

  defp shift(segment, rows, cols) do
    Regex.replace(@token, segment, fn
      _whole, c_anchor, letters, r_anchor, digits, "", "", "", "", "", "", "", "" ->
        cell(c_anchor, letters, r_anchor, digits, rows, cols)

      _whole, _, _, _, _, from_anchor, from, to_anchor, to, "", "", "", "" ->
        columns(from_anchor, from, to_anchor, to, cols)

      _whole, _, _, _, _, _, _, _, _, from_anchor, from, to_anchor, to ->
        row_range(from_anchor, from, to_anchor, to, rows)
    end)
  end

  defp cell(c_anchor, letters, r_anchor, digits, rows, cols) do
    with {:ok, col} <- column(c_anchor, letters, cols),
         {:ok, row} <- row(r_anchor, digits, rows) do
      c_anchor <> col <> r_anchor <> row
    else
      :error -> "#REF!"
    end
  end

  defp columns(from_anchor, from, to_anchor, to, cols) do
    with {:ok, from} <- column(from_anchor, from, cols),
         {:ok, to} <- column(to_anchor, to, cols) do
      from_anchor <> from <> ":" <> to_anchor <> to
    else
      :error -> "#REF!"
    end
  end

  defp row_range(from_anchor, from, to_anchor, to, rows) do
    with {:ok, from} <- row(from_anchor, from, rows),
         {:ok, to} <- row(to_anchor, to, rows) do
      from_anchor <> from <> ":" <> to_anchor <> to
    else
      :error -> "#REF!"
    end
  end

  defp column("$", letters, _cols), do: {:ok, letters}

  defp column("", letters, cols) do
    case A1.letters_to_col(letters) + cols do
      col when col >= 0 and col <= @last_col -> {:ok, A1.col_to_letters(col)}
      _off -> :error
    end
  end

  defp row("$", digits, _rows), do: {:ok, digits}

  defp row("", digits, rows) do
    case String.to_integer(digits) + rows do
      row when row >= 1 and row <= @last_row -> {:ok, Integer.to_string(row)}
      _off -> :error
    end
  end
end
