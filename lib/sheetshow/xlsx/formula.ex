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
  @token ~r/
    (?<![A-Za-z0-9_.$])
    (?:
      (\$?)([A-Za-z]{1,3})(\$?)([0-9]+)(?![A-Za-z0-9_(])
      |
      (\$?)([A-Za-z]{1,3}):(\$?)([A-Za-z]{1,3})(?![A-Za-z0-9_(])
      |
      (\$?)([0-9]+):(\$?)([0-9]+)(?![A-Za-z0-9_(])
    )
  /x

  # A string literal in double quotes, or a sheet name in single ones, either
  # doubling its own quote inside. Nothing inside either is a reference.
  @literal ~r/"(?:[^"]|"")*"|'(?:[^']|'')*'/

  @doc """
  The formula as it reads `rows` down and `cols` across from where it was
  written, without its leading `=`.

      iex> Sheetshow.Xlsx.Formula.translate("A1*2+$B$1", 3, 1)
      "B4*2+$B$1"
      iex> Sheetshow.Xlsx.Formula.translate(~s|SUM(A:A)&"A1"&'Q1 costs'!B2|, 0, 2)
      ~s|SUM(C:C)&"A1"&'Q1 costs'!D2|
      iex> Sheetshow.Xlsx.Formula.translate("A1", -1, 0)
      "#REF!"
  """
  @spec translate(String.t(), integer(), integer()) :: String.t()
  def translate(formula, 0, 0), do: formula

  def translate(formula, rows, cols) when is_binary(formula) do
    @literal
    |> Regex.split(formula, include_captures: true)
    |> Enum.map_join(fn
      <<quote, _::binary>> = literal when quote in [?", ?'] -> literal
      segment -> shift(segment, rows, cols)
    end)
  end

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
      col when col >= 0 -> {:ok, A1.col_to_letters(col)}
      _off -> :error
    end
  end

  defp row("$", digits, _rows), do: {:ok, digits}

  defp row("", digits, rows) do
    case String.to_integer(digits) + rows do
      row when row >= 1 -> {:ok, Integer.to_string(row)}
      _off -> :error
    end
  end
end
