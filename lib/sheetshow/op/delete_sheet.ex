defmodule Sheetshow.Op.DeleteSheet do
  @moduledoc """
  Removes a tab, and everything on it.

      iex> Sheetshow.Op.DeleteSheet.new("log")
      %Sheetshow.Op.DeleteSheet{title: "log"}

  Nothing plans one of these for you: losing a sheet is not something a write
  should decide on your behalf, so it is yours to ask for.
  """

  @enforce_keys [:title]
  defstruct [:title]

  @type t :: %__MODULE__{title: String.t()}

  @doc "Builds the op."
  @spec new(String.t()) :: t()
  def new(title) when is_binary(title) and title != "", do: %__MODULE__{title: title}
end
