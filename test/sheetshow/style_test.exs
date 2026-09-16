defmodule Sheetshow.StyleTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.Style

  alias Sheetshow.Style

  @full %{
    bold: true,
    italic: false,
    underline: true,
    strikethrough: false,
    font_size: 11,
    font_family: "Roboto",
    color: "#202124",
    background: "#fff2cc",
    horizontal: :center,
    vertical: :middle,
    wrap: :wrap,
    number_format: "#,##0.00",
    col_width: 120,
    row_height: 21
  }

  test "every documented key validates, and the vocabulary is exactly those keys" do
    assert Style.validate(@full) == :ok
    assert Enum.sort(Map.keys(@full)) == Enum.sort(Style.keys())
    assert Style.validate(%{}) == :ok
  end

  test "each bad value is reported with its key" do
    for {key, value} <- [
          {:bold, "yes"},
          {:font_size, 0},
          {:font_size, 11.5},
          {:font_family, ""},
          {:color, "red"},
          {:color, "#FFF"},
          {:background, "FFF2CC"},
          {:horizontal, :middle},
          {:vertical, :center},
          {:wrap, "wrap"},
          {:number_format, ""},
          {:col_width, -1},
          {:row_height, 0}
        ] do
      assert {:error,
              %Sheetshow.Error{reason: :invalid_style, details: %{key: ^key, value: ^value}}} =
               Style.validate(Map.put(@full, key, value))
    end
  end

  test "unknown and non-atom keys are rejected" do
    assert {:error, %Sheetshow.Error{details: %{key: :bolt}}} = Style.validate(%{bolt: true})
    assert {:error, %Sheetshow.Error{details: %{key: "bold"}}} = Style.validate(%{"bold" => true})
  end

  test "a style must be a plain map" do
    assert {:error, %Sheetshow.Error{reason: :invalid_style}} = Style.validate(bold: true)
    assert {:error, %Sheetshow.Error{reason: :invalid_style}} = Style.validate(~D[2026-09-12])
    refute Style.valid?(nil)
  end

  test "colours round-trip through rgb" do
    for hex <- ["#000000", "#FFFFFF", "#FF8800", "#0A0B0C"] do
      assert hex |> Style.hex_to_rgb() |> Style.rgb_to_hex() == hex
    end

    assert Style.hex_to_rgb("#ff8800") == {255, 136, 0}
  end
end
