defmodule Sheetshow.CellError do
  @moduledoc """
  What a formula worked out to, when it did not work out.

      iex> Sheetshow.CellError.new("DIVIDE_BY_ZERO", "Function DIVIDE parameter 2 cannot be zero.")
      %Sheetshow.CellError{type: :divide_by_zero, message: "Function DIVIDE parameter 2 cannot be zero."}

  These are never cell values. A cell holds what you would type into it (a
  number, a string, a formula), and `#DIV/0!` is not something you can type; it
  is what Sheets made of what you typed. So it arrives in a cell's `meta` under
  `:effective`, alongside `:formatted`, and `Sheetshow.Value` need never know
  it exists.
  """

  @enforce_keys [:type]
  defstruct [:type, :message]

  @type t :: %__MODULE__{type: atom() | String.t(), message: String.t() | nil}

  @types %{
    "ERROR" => :error,
    "NULL_VALUE" => :null_value,
    "DIVIDE_BY_ZERO" => :divide_by_zero,
    "VALUE" => :value,
    "REF" => :ref,
    "NAME" => :name,
    "NUM" => :num,
    "N_A" => :n_a,
    "LOADING" => :loading
  }

  @doc """
  Builds one from what Google calls it. A type we do not know stays the string
  Google sent, rather than becoming an atom, because atoms are never collected
  and this comes off the wire.

      iex> Sheetshow.CellError.new("REF").type
      :ref
      iex> Sheetshow.CellError.new("SOMETHING_NEW").type
      "SOMETHING_NEW"
  """
  @spec new(String.t(), String.t() | nil) :: t()
  def new(type, message \\ nil) when is_binary(type) do
    %__MODULE__{type: Map.get(@types, type, type), message: message}
  end

  # The text a spreadsheet spells each error with, keyed by the atom `new/1`
  # makes. A type not here was one we did not recognise on the way in, whose type
  # is already the original text.
  @text %{
    error: "#ERROR!",
    null_value: "#NULL!",
    divide_by_zero: "#DIV/0!",
    value: "#VALUE!",
    ref: "#REF!",
    name: "#NAME?",
    num: "#NUM!",
    n_a: "#N/A",
    loading: "#GETTING_DATA"
  }

  @doc """
  The text a spreadsheet shows for the error, which is also what a values read
  gives back for it: unlike a cell read, a values read cannot say a `#DIV/0!` is
  an error rather than someone typing that string, so it arrives as the string.

      iex> Sheetshow.CellError.new("DIVIDE_BY_ZERO") |> Sheetshow.CellError.to_text()
      "#DIV/0!"
  """
  @spec to_text(t()) :: String.t()
  def to_text(%__MODULE__{type: type}), do: Map.get(@text, type, type)
end
