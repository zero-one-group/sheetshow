defmodule Sheetshow.Xlsx.Strings do
  @moduledoc false
  # sharedStrings.xml: the table of text a worksheet's `t="s"` cells index into.
  #
  # Not every workbook has one. Excel shares its strings; other writers put the
  # text in the cell as `t="inlineStr"` and ship no table at all, so a missing
  # part is ordinary rather than an error.

  alias Sheetshow.Xlsx.Xml

  defstruct table: {}, index: %{}, added: [], shared?: false

  @type t :: %__MODULE__{
          table: tuple(),
          index: %{String.t() => non_neg_integer()},
          added: [String.t()],
          shared?: boolean()
        }

  @doc "The empty table, for a workbook with no sharedStrings.xml."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  An empty table that a workbook nonetheless has, for one we are making
  ourselves. A spreadsheet used as a database repeats itself (a status, a
  category, an id written twice), and a table is what stops every repetition
  costing its own bytes.
  """
  @spec shared() :: t()
  def shared, do: %__MODULE__{shared?: true}

  @doc "How many strings the table holds."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{table: table}), do: tuple_size(table)

  @doc """
  The string at an index. Out of range is nil rather than an error: a cell
  pointing past the end of the table has lost its text either way, and losing
  one cell beats losing the read.
  """
  @spec fetch(t(), integer()) :: String.t() | nil
  def fetch(%__MODULE__{table: table}, index)
      when is_integer(index) and index >= 0 and index < tuple_size(table),
      do: elem(table, index)

  def fetch(%__MODULE__{}, _index), do: nil

  @doc """
  Reads sharedStrings.xml.

  Each `<si>` is one string. Plain text sits in a single `<t>`; text that was
  formatted a piece at a time is split across `<r><t>` runs which read as one
  string, since Sheetshow styles a cell rather than a stretch of its text.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, Sheetshow.Error.t()}
  def parse(xml) when is_binary(xml) do
    initial = %{strings: [], current: nil, chars: [], collecting: false, phonetic: false}

    with {:ok, state} <- Xml.fold(xml, "xl/sharedStrings.xml", initial, &event/2) do
      strings = Enum.reverse(state.strings)

      {:ok,
       %__MODULE__{
         table: List.to_tuple(strings),
         # First occurrence wins, so writing a string the table already holds
         # points at the one already there rather than adding a duplicate.
         index: strings |> Enum.with_index() |> Enum.reverse() |> Map.new(),
         shared?: true
       }}
    end
  end

  @doc """
  The index to write for a string, and the table to write out afterwards.

  A string the table already holds keeps its index. A new one is **appended**,
  never inserted: every `t="s"` cell in every sheet we did not touch points into
  this table by position, so renumbering it would silently move other people's
  text around.

  A workbook that shares no strings, because one writer puts the text in the
  cell instead, gets `:inline` back, and the cell carries its own text rather
  than gaining a table the file never had.
  """
  @spec put(t(), String.t()) :: {non_neg_integer() | :inline, t()}
  def put(%__MODULE__{shared?: false} = strings, _string), do: {:inline, strings}

  def put(%__MODULE__{} = strings, string) do
    case Map.fetch(strings.index, string) do
      {:ok, index} ->
        {index, strings}

      :error ->
        index = tuple_size(strings.table) + length(strings.added)

        {index,
         %{
           strings
           | index: Map.put(strings.index, string, index),
             added: [string | strings.added]
         }}
    end
  end

  @doc "Whether anything has been added since the table was read."
  @spec added?(t()) :: boolean()
  def added?(%__MODULE__{added: added}), do: added != []

  @doc """
  sharedStrings.xml as it should now be written: everything that was there, in
  the order it was there, and whatever `put/2` appended after it.
  """
  @spec render(t()) :: iodata()
  def render(%__MODULE__{} = strings) do
    all = Tuple.to_list(strings.table) ++ Enum.reverse(strings.added)
    count = length(all)

    [
      ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>),
      ~s(<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ),
      ~s(count="#{count}" uniqueCount="#{count}">),
      Enum.map(all, &[~s(<si><t xml:space="preserve">), Xml.escape(&1), "</t></si>"]),
      "</sst>"
    ]
  end

  defp event({:startElement, _uri, ~c"si", _q, _attrs}, state), do: %{state | current: []}

  defp event({:endElement, _uri, ~c"si", _q}, %{current: current} = state)
       when is_list(current) do
    string = current |> Enum.reverse() |> IO.iodata_to_binary()
    %{state | strings: [string | state.strings], current: nil}
  end

  defp event(
         {:startElement, _uri, ~c"t", _q, _attrs},
         %{current: current, phonetic: false} = state
       )
       when is_list(current),
       do: %{state | collecting: true, chars: []}

  defp event({:endElement, _uri, ~c"t", _q}, %{collecting: true} = state) do
    %{state | collecting: false, chars: [], current: [Xml.text(state.chars) | state.current]}
  end

  # <rPh> carries the phonetic hints a Japanese workbook puts beside a run:
  # the reading of the characters, not the characters. A reader that collects
  # them gets every such string twice over.
  defp event({:startElement, _uri, ~c"rPh", _q, _attrs}, state), do: %{state | phonetic: true}
  defp event({:endElement, _uri, ~c"rPh", _q}, state), do: %{state | phonetic: false}

  defp event({:characters, chars}, %{collecting: true} = state),
    do: %{state | chars: [chars | state.chars]}

  defp event(_event, state), do: state
end
