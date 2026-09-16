defmodule Sheetshow.Style do
  @moduledoc """
  How a cell looks: a plain map with atom keys, so styles compose with
  `Map.merge/2` and read well when inspected.

      %{bold: true, background: "#FFF2CC", number_format: "0.00%"}

  | Key              | Value                                   |
  |------------------|-----------------------------------------|
  | `:bold`, `:italic`, `:underline`, `:strikethrough` | `boolean()` |
  | `:font_size`     | points, a positive integer              |
  | `:font_family`   | `"Roboto"`                              |
  | `:color`         | text colour, `"#RRGGBB"`                |
  | `:background`    | fill colour, `"#RRGGBB"`                |
  | `:horizontal`    | `:left`, `:center` or `:right`          |
  | `:vertical`      | `:top`, `:middle` or `:bottom`          |
  | `:wrap`          | `:overflow`, `:clip` or `:wrap`         |
  | `:number_format` | a Sheets pattern, `"#,##0.00"`, `"yyyy-mm-dd"` |
  | `:col_width`     | pixels, a positive integer              |
  | `:row_height`    | pixels, a positive integer              |

  `:col_width` and `:row_height` describe the column and row the cell sits in
  rather than the cell; writers lift them out. Validation happens where a style
  is about to be written, not when you build it.
  """

  alias Sheetshow.Error

  @type color :: String.t()
  @type t :: %{optional(atom()) => term()}

  @booleans [:bold, :italic, :underline, :strikethrough]
  @pixels [:col_width, :row_height]
  @enums %{
    horizontal: [:left, :center, :right],
    vertical: [:top, :middle, :bottom],
    wrap: [:overflow, :clip, :wrap]
  }
  @keys @booleans ++
          @pixels ++
          Map.keys(@enums) ++ [:font_size, :font_family, :color, :background, :number_format]

  @hex ~r/^#[0-9A-Fa-f]{6}$/

  @doc "Every key a style may have."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc """
  Checks every key and value.

      iex> Sheetshow.Style.validate(%{bold: true, horizontal: :center})
      :ok
      iex> {:error, %Sheetshow.Error{reason: :invalid_style, details: %{key: :bolt}}} =
      ...>   Sheetshow.Style.validate(%{bolt: true})
      iex> {:error, %Sheetshow.Error{details: %{key: :font_size, value: 0}}} =
      ...>   Sheetshow.Style.validate(%{font_size: 0})
  """
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(style) when is_map(style) and not is_struct(style) do
    Enum.find_value(style, :ok, fn {key, value} ->
      case check(key, value) do
        :ok -> nil
        {:error, why} -> {:error, invalid(key, value, why)}
      end
    end)
  end

  def validate(other) do
    {:error,
     Error.new(:invalid_style, "a style must be a map, got #{inspect(other)}", value: other)}
  end

  @doc "Whether the term is a valid style."
  @spec valid?(term()) :: boolean()
  def valid?(style), do: validate(style) == :ok

  defp check(key, _value) when key not in @keys, do: {:error, "unknown style key"}
  defp check(key, value) when key in @booleans and is_boolean(value), do: :ok
  defp check(key, value) when key in @pixels and is_integer(value) and value > 0, do: :ok
  defp check(:font_size, value) when is_integer(value) and value > 0, do: :ok
  defp check(:font_family, value) when is_binary(value) and value != "", do: :ok
  defp check(:number_format, value) when is_binary(value) and value != "", do: :ok

  defp check(key, value) when key in [:color, :background] do
    if is_binary(value) and Regex.match?(@hex, value),
      do: :ok,
      else: {:error, "expected \"#RRGGBB\""}
  end

  defp check(key, value) when is_map_key(@enums, key) do
    allowed = Map.fetch!(@enums, key)
    if value in allowed, do: :ok, else: {:error, "expected one of #{inspect(allowed)}"}
  end

  defp check(key, _value) when key in @booleans, do: {:error, "expected a boolean"}

  defp check(key, _value) when key in @pixels or key == :font_size,
    do: {:error, "expected a positive integer"}

  defp check(_key, _value), do: {:error, "expected a non-empty string"}

  defp invalid(key, value, why) do
    Error.new(:invalid_style, "invalid style #{inspect(key)}: #{inspect(value)} (#{why})",
      key: key,
      value: value
    )
  end

  @doc """
  A `"#RRGGBB"` colour as `{red, green, blue}` in 0..255.

      iex> Sheetshow.Style.hex_to_rgb("#FF8800")
      {255, 136, 0}
  """
  @spec hex_to_rgb(color()) :: {0..255, 0..255, 0..255}
  def hex_to_rgb("#" <> <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  @doc """
  `{red, green, blue}` in 0..255 as `"#RRGGBB"`.

      iex> Sheetshow.Style.rgb_to_hex({255, 136, 0})
      "#FF8800"
  """
  @spec rgb_to_hex({0..255, 0..255, 0..255}) :: color()
  def rgb_to_hex({r, g, b}) when r in 0..255 and g in 0..255 and b in 0..255 do
    "#" <> Enum.map_join([r, g, b], &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
  end
end
