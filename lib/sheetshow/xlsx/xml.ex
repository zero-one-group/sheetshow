defmodule Sheetshow.Xlsx.Xml do
  @moduledoc false
  # The only XML parsing in the library, and the only sanctioned way in.
  #
  # `:xmerl_sax_parser`, never `:xmerl_scan`. The DOM parser reads a worksheet
  # at 0.6-0.9 MB/s and takes about ninety times the input in heap, which on a
  # workbook of any size is not slow but impossible; the SAX parser reads the
  # same bytes at ~15 MB/s in constant space. Measured, both of them.

  alias Sheetshow.Error

  @type attrs :: [{charlist(), charlist(), charlist(), charlist()}]
  @type event :: term()

  @doc """
  Folds an event function over the document. The function takes an event and
  the state, and gives back the next state; anything it raises comes back as an
  error naming the part, so one damaged sheet is an error rather than a crash.
  """
  @spec fold(binary(), String.t(), term(), (event(), term() -> term())) ::
          {:ok, term()} | {:error, Error.t()}
  def fold(xml, part, initial, fun) when is_binary(xml) and is_function(fun, 2) do
    handler = fn event, _location, state -> fun.(event, state) end

    case :xmerl_sax_parser.stream(xml, [
           {:event_fun, handler},
           {:event_state, initial},
           {:encoding, :utf8}
         ]) do
      {:ok, state, _rest} ->
        {:ok, state}

      {:fatal_error, _location, reason, _tags, _state} ->
        {:error, invalid(part, reason)}

      # What a parse gets when the event function itself raises.
      {:fatal_error, %{__exception__: true} = exception} ->
        {:error, invalid(part, Exception.message(exception))}

      other ->
        {:error, invalid(part, other)}
    end
  rescue
    error -> {:error, invalid(part, Exception.message(error))}
  end

  @doc """
  Text as it can go inside an element or an attribute.

  The four that need escaping somewhere, so one function is safe in both places
  rather than two that have to be told apart. Characters XML 1.0 does not allow
  at all (the control codes below space, bar tab, newline and return) are
  dropped rather than written, because a file holding one does not open.

      iex> Sheetshow.Xlsx.Xml.escape(~s(a & b < c)) |> IO.iodata_to_binary()
      "a &amp; b &lt; c"
  """
  @spec escape(String.t()) :: iodata()
  def escape(text) when is_binary(text) do
    text
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "")
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s("), "&quot;")
  end

  @doc """
  Collected character chunks as a string, newest chunk first.

  Not `IO.iodata_to_binary/1`: a SAX parser hands back codepoints, and a
  codepoint above 255 is not a byte, so anything outside Latin-1 raises there,
  which is most of the world's spreadsheets.
  """
  @spec text([charlist() | binary()]) :: binary()
  def text(chunks) do
    chunks |> Enum.reverse() |> :unicode.characters_to_binary()
  end

  @doc """
  Decodes SpreadsheetML string escaping, which is not XML escaping and is not
  undone by the parser. A character a string cannot spell as itself is written
  `_xHHHH_` (four hex digits), and a literal underscore that would otherwise
  start such a run is itself written `_x005F_`. Both read back in one
  left-to-right pass, so `_x005F_x0041_` is the literal text `_x0041_`, not the
  letter it would name.

      iex> Sheetshow.Xlsx.Xml.unescape_string("_x0041_")
      "A"
      iex> Sheetshow.Xlsx.Xml.unescape_string("_x005F_x0041_")
      "_x0041_"
  """
  @spec unescape_string(String.t()) :: String.t()
  def unescape_string(text) when is_binary(text) do
    Regex.replace(~r/_x([0-9A-Fa-f]{4})_/, text, fn _, hex ->
      <<String.to_integer(hex, 16)::utf8>>
    end)
  end

  @doc """
  Escapes a string the SpreadsheetML way, the inverse of `unescape_string/1`, so
  a literal `_x0041_` or a control character survives a round trip rather than
  being read as the character it looks like. XML-escapes the result too, since a
  written string needs both.
  """
  @spec escape_string(String.t()) :: iodata()
  def escape_string(text) when is_binary(text) do
    text
    |> String.replace(~r/_(?=x[0-9A-Fa-f]{4}_)/, "_x005F_")
    |> escape_controls()
    |> escape()
  end

  # Everything below a space bar the tab and newline, the carriage return among
  # them: a parser folds a literal return into a newline, so the only way to keep
  # one is to escape it, which is what a writer of these files does.
  defp escape_controls(text) do
    String.replace(text, ~r/[\x00-\x08\x0B-\x1F]/, fn <<code>> ->
      "_x" <>
        (code |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0")) <> "_"
    end)
  end

  @doc """
  An attribute's value as a string, or nil. Matched on local name alone: a
  writer may declare its namespaces on the root element or on the element that
  uses them, and both are in the wild.
  """
  @spec attr(attrs(), charlist()) :: String.t() | nil
  def attr(attrs, name) do
    Enum.find_value(attrs, fn
      {_uri, _prefix, ^name, value} -> List.to_string(value)
      _ -> nil
    end)
  end

  @doc "An attribute as an integer, or the default when it is absent or not one."
  @spec int(attrs(), charlist(), integer() | nil) :: integer() | nil
  def int(attrs, name, default \\ nil) do
    with value when is_binary(value) <- attr(attrs, name),
         {int, ""} <- Integer.parse(value) do
      int
    else
      _ -> default
    end
  end

  @doc "An attribute as a float, or the default."
  @spec number(attrs(), charlist(), number() | nil) :: number() | nil
  def number(attrs, name, default \\ nil) do
    case attr(attrs, name) do
      nil -> default
      value -> parse_number(value, default)
    end
  end

  @doc """
  A number as a spreadsheet writes one: an integer where it can be, a float
  otherwise. `"1000"` is 1000 and not 1000.0, which is what a cell holding a
  count should read back as.
  """
  @spec parse_number(String.t(), term()) :: number() | term()
  def parse_number(text, default \\ nil) do
    case Integer.parse(text) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(text) do
          {float, ""} -> float
          _ -> default
        end
    end
  end

  @doc """
  An xlsx colour (`AARRGGBB`, alpha first) as the `#RRGGBB` a style wants.
  A theme or indexed colour needs the theme part to resolve and comes back nil,
  which leaves the cell without that key rather than with a wrong one.
  """
  @spec color(attrs()) :: String.t() | nil
  def color(attrs) do
    case attr(attrs, ~c"rgb") do
      <<_alpha::binary-size(2), rgb::binary-size(6)>> -> "#" <> String.upcase(rgb)
      <<"#", rgb::binary-size(6)>> -> "#" <> String.upcase(rgb)
      <<rgb::binary-size(6)>> -> "#" <> String.upcase(rgb)
      _ -> nil
    end
  end

  @doc """
  Whether an xlsx boolean attribute is on. Absent means on for the flags that
  are written bare (`<b/>`), so the caller decides the default.
  """
  @spec flag(attrs(), charlist(), boolean()) :: boolean()
  def flag(attrs, name, default \\ true) do
    case attr(attrs, name) do
      nil -> default
      "0" -> false
      "false" -> false
      _ -> true
    end
  end

  defp invalid(part, reason) do
    Error.new(:invalid_xlsx, "#{part} is not XML Sheetshow can read: #{inspect(reason)}",
      part: part
    )
  end
end
