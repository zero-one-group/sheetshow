defmodule Sheetshow.Cell do
  @moduledoc """
  A cell: where it is, what it holds, how it looks.

      iex> Sheetshow.Cell.new("Costs!B4", 0.22, %{number_format: "0%"})
      %Sheetshow.Cell{
        coord: %Sheetshow.Coord{row: 3, col: 1, sheet: "Costs"},
        value: 0.22,
        style: %{number_format: "0%"},
        meta: %{}
      }

  A spreadsheet is a list of these, in no particular order. Knowing cells, you
  know most of Sheetshow: everything else builds lists of them, moves them
  about, or turns them into requests.

  `meta` is yours. No writer looks at it; readers put what they learned there,
  such as the text Sheets displayed for a value. Values and styles are checked
  by `validate/1`, which writers call, rather than on construction.
  """

  alias Sheetshow.{Coord, Error, Style, Value}

  @enforce_keys [:coord]
  defstruct [:coord, value: nil, style: %{}, meta: %{}]

  @type t :: %__MODULE__{coord: Coord.t(), value: Value.t(), style: Style.t(), meta: map()}

  @doc """
  Builds a cell at a `Sheetshow.Coord` or an A1 reference (raising if the
  reference is malformed).

      iex> Sheetshow.Cell.new(Sheetshow.Coord.new(0, 0), "Item")
      %Sheetshow.Cell{coord: %Sheetshow.Coord{row: 0, col: 0, sheet: nil}, value: "Item", style: %{}, meta: %{}}
  """
  @spec new(Coord.t() | String.t(), Value.t(), Style.t()) :: t()
  def new(coord, value \\ nil, style \\ %{})

  def new(%Coord{} = coord, value, style) when is_map(style) do
    %__MODULE__{coord: coord, value: value, style: style}
  end

  def new(a1, value, style) when is_binary(a1), do: new(Coord.from_a1!(a1), value, style)

  @doc """
  Checks the coordinate, value and style.

      iex> Sheetshow.Cell.validate(Sheetshow.Cell.new("A1", 1, %{bold: true}))
      :ok
      iex> {:error, %Sheetshow.Error{reason: :invalid_style}} =
      ...>   Sheetshow.Cell.validate(Sheetshow.Cell.new("A1", 1, %{bold: "yes"}))
  """
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{coord: %Coord{}, value: value, style: style} = cell) do
    with :ok <- Value.validate(value),
         :ok <- Style.validate(style) do
      :ok
    else
      {:error, error} -> {:error, %{error | details: Map.put(error.details, :cell, cell)}}
    end
  end

  def validate(other) do
    {:error,
     Error.new(:invalid_cell, "not a cell with a coordinate: #{inspect(other)}", cell: other)}
  end

  @doc "Whether the term is a valid cell."
  @spec valid?(term()) :: boolean()
  def valid?(cell), do: validate(cell) == :ok

  @doc """
  Merges a style into the cell's, the new keys winning.

      iex> Sheetshow.Cell.new("A1", 1, %{bold: true})
      ...> |> Sheetshow.Cell.put_style(%{bold: false, italic: true})
      ...> |> Map.fetch!(:style)
      %{bold: false, italic: true}
  """
  @spec put_style(t(), Style.t()) :: t()
  def put_style(%__MODULE__{style: style} = cell, more) when is_map(more) do
    %{cell | style: Map.merge(style, more)}
  end

  @doc """
  Moves the cell by `rows` down and `cols` right; see `Sheetshow.Coord.shift/3`.

      iex> Sheetshow.Cell.new("A1") |> Sheetshow.Cell.shift(1, 2) |> Map.fetch!(:coord) |> Sheetshow.Coord.to_a1()
      "C2"
  """
  @spec shift(t(), integer(), integer()) :: t()
  def shift(%__MODULE__{coord: coord} = cell, rows, cols) do
    %{cell | coord: Coord.shift(coord, rows, cols)}
  end

  @doc false
  # A date, time or datetime is a number until a number format says otherwise,
  # so a temporal value whose style has no `:number_format` gets the one that
  # makes it readable. Every writer does this on its way out.
  @spec with_number_format(t()) :: t()
  def with_number_format(%__MODULE__{value: value, style: style} = cell) do
    case {Map.has_key?(style, :number_format), Value.default_number_format(value)} do
      {false, format} when is_binary(format) ->
        %{cell | style: Map.put(style, :number_format, format)}

      _ ->
        cell
    end
  end

  @doc """
  Puts the cell on a sheet.

      iex> Sheetshow.Cell.new("A1") |> Sheetshow.Cell.put_sheet("Costs") |> Map.fetch!(:coord) |> Sheetshow.Coord.to_a1()
      "Costs!A1"
  """
  @spec put_sheet(t(), String.t() | nil) :: t()
  def put_sheet(%__MODULE__{coord: coord} = cell, sheet) when is_binary(sheet) or is_nil(sheet) do
    %{cell | coord: %{coord | sheet: sheet}}
  end
end
