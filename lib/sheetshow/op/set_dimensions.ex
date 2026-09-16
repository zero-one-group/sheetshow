defmodule Sheetshow.Op.SetDimensions do
  @moduledoc """
  Sets the width of columns or the height of rows, in pixels.

  `indexes` is 0-indexed and inclusive, and `axis` says which dimension they
  count. Widths and heights belong to the grid rather than to any cell, which
  is why the `:col_width` and `:row_height` styles are lifted out into ops of
  their own.

      iex> Sheetshow.Op.SetDimensions.new("Costs", :cols, 0..1, 180)
      %Sheetshow.Op.SetDimensions{sheet: "Costs", axis: :cols, indexes: 0..1, pixels: 180}
  """

  @enforce_keys [:sheet, :axis, :indexes, :pixels]
  defstruct [:sheet, :axis, :indexes, :pixels]

  @type axis :: :rows | :cols
  @type t :: %__MODULE__{
          sheet: String.t(),
          axis: axis(),
          indexes: Range.t(),
          pixels: pos_integer()
        }

  @doc """
  Builds the op. The indexes must ascend by one from 0 or later, and the size
  must be a positive number of pixels.

      iex> Sheetshow.Op.SetDimensions.new("Costs", :rows, 2..2, 40).indexes
      2..2
  """
  @spec new(String.t(), axis(), Range.t(), pos_integer()) :: t()
  def new(sheet, axis, first..last//1 = indexes, pixels)
      when is_binary(sheet) and axis in [:rows, :cols] and first >= 0 and last >= first and
             is_integer(pixels) and pixels > 0 do
    %__MODULE__{sheet: sheet, axis: axis, indexes: indexes, pixels: pixels}
  end
end
