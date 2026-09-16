defmodule Sheetshow.Op.DeleteRows do
  @moduledoc """
  Removes rows; everything below moves up.

  `rows` is 0-indexed and inclusive, like every range in Sheetshow. Deleting
  rows shifts the ones below, so a plan with more than one of these applies
  them bottom-up, or the second one deletes the wrong rows.

      iex> Sheetshow.Op.DeleteRows.new("log", 2..4)
      %Sheetshow.Op.DeleteRows{sheet: "log", rows: 2..4}
  """

  @enforce_keys [:sheet, :rows]
  defstruct [:sheet, :rows]

  @type t :: %__MODULE__{sheet: String.t(), rows: Range.t()}

  @doc """
  Builds the op. The rows must ascend by one and start at or after row 0.

      iex> Sheetshow.Op.DeleteRows.new("log", 3..3) |> Sheetshow.Op.DeleteRows.count()
      1
  """
  @spec new(String.t(), Range.t()) :: t()
  def new(sheet, first..last//1 = rows) when is_binary(sheet) and first >= 0 and last >= first do
    %__MODULE__{sheet: sheet, rows: rows}
  end

  @doc "How many rows the op removes."
  @spec count(t()) :: pos_integer()
  def count(%__MODULE__{rows: first..last//1}), do: last - first + 1
end
