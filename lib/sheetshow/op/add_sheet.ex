defmodule Sheetshow.Op.AddSheet do
  @moduledoc """
  Adds a tab. Adding one that already exists is an error, here and at Google,
  so a plan says what it expects to find.

      iex> Sheetshow.Op.AddSheet.new("Costs")
      %Sheetshow.Op.AddSheet{title: "Costs"}
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
