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
  def new(title) when is_binary(title) and title != "" do
    # A title is text, and text is UTF-8: a Latin-1 byte in one is written into
    # a file that then does not open, and makes a request Google cannot parse.
    unless String.valid?(title),
      do: raise(ArgumentError, "a sheet title is UTF-8, got #{inspect(title)}")

    %__MODULE__{title: title}
  end
end
