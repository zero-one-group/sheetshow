defmodule Sheetshow.A1Test do
  use ExUnit.Case, async: true
  doctest Sheetshow.A1

  alias Sheetshow.A1

  describe "column letters" do
    test "known anchors" do
      for {col, letters} <- [
            {0, "A"},
            {25, "Z"},
            {26, "AA"},
            {51, "AZ"},
            {52, "BA"},
            {701, "ZZ"},
            {702, "AAA"},
            {18_277, "ZZZ"}
          ] do
        assert A1.col_to_letters(col) == letters
        assert A1.letters_to_col(letters) == col
      end
    end

    test "round-trip over the first twenty thousand columns" do
      for col <- 0..20_000 do
        assert col |> A1.col_to_letters() |> A1.letters_to_col() == col
      end
    end

    test "letters_to_col rejects anything but letters" do
      for bad <- ["", "A1", "$A", "A-B", " "] do
        assert_raise ArgumentError, fn -> A1.letters_to_col(bad) end
      end
    end
  end

  describe "sheet names" do
    test "quote_sheet round-trips through split_sheet" do
      for name <- [
            "Costs",
            "Q1 costs",
            "Q1's",
            "it's 'quoted'",
            "2024",
            "Tab1",
            "A",
            "a!b",
            "'"
          ] do
        assert {:ok, {^name, "A1"}} = A1.split_sheet(A1.quote_sheet(name) <> "!A1")

        assert {:ok, %Sheetshow.Range{sheet: ^name}} =
                 Sheetshow.Range.from_a1(A1.quote_sheet(name))
      end
    end

    test "quote_sheet leaves plain names alone, even short ones" do
      for name <- ["log", "A", "Costs", "raw_2024"], do: assert(A1.quote_sheet(name) == name)
    end

    test "split_sheet errors" do
      for bad <- ["!A1", "'Costs", "''!A1", "'Costs'!A1!B2"] do
        assert {:error, %Sheetshow.Error{reason: :invalid_a1}} = A1.split_sheet(bad)
      end
    end
  end

  describe "parse_ref" do
    test "accepts anchors and lowercase" do
      assert {:ok, {1, 3}} = A1.parse_ref("$b$4")
    end

    test "rejects malformed endpoints" do
      for bad <- ["", "$", "A0", "A01", "1A", "AAAA1", "A1B", "A 1"] do
        assert :error = A1.parse_ref(bad)
      end
    end
  end
end
