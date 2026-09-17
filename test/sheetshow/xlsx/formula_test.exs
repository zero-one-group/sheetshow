defmodule Sheetshow.Xlsx.FormulaTest do
  use ExUnit.Case, async: true

  doctest Sheetshow.Xlsx.Formula

  alias Sheetshow.Xlsx.Formula

  describe "what moves" do
    test "a relative reference moves with the cell" do
      assert Formula.translate("A1", 2, 3) == "D3"
      assert Formula.translate("SUM(A1:B2)", 1, 1) == "SUM(B2:C3)"
    end

    test "an anchored row or column stays where it is" do
      assert Formula.translate("$A$1", 2, 3) == "$A$1"
      assert Formula.translate("$A1", 2, 3) == "$A3"
      assert Formula.translate("A$1", 2, 3) == "D$1"
    end

    test "whole columns move across and whole rows move down" do
      assert Formula.translate("SUM(A:A)", 5, 2) == "SUM(C:C)"
      assert Formula.translate("SUM(1:1)", 5, 2) == "SUM(6:6)"
      assert Formula.translate("SUM($A:B)", 0, 1) == "SUM($A:C)"
    end

    test "lowercase letters are read, and come out in the upper case a file stores" do
      assert Formula.translate("a1+B2", 1, 1) == "B2+C3"
    end

    test "a reference moved off the sheet is #REF!" do
      assert Formula.translate("A1", -1, 0) == "#REF!"
      assert Formula.translate("A1", 0, -1) == "#REF!"
      assert Formula.translate("A:A", 0, -1) == "#REF!"
      assert Formula.translate("$A$1+A1", -1, 0) == "$A$1+#REF!"
    end

    test "no move is no change, whatever the formula holds" do
      formula = ~s|IF(A1="x",'Q1 costs'!B2,LOG10(C3))|
      assert Formula.translate(formula, 0, 0) == formula
    end
  end

  describe "what does not" do
    test "text inside a string literal, quotes doubled or not" do
      assert Formula.translate(~s("A1"&A1), 1, 0) == ~s("A1"&A2)
      assert Formula.translate(~s("say ""A1"""&A1), 1, 0) == ~s("say ""A1"""&A2)
    end

    test "a sheet name in single quotes, though the reference after it moves" do
      assert Formula.translate("'Q1 costs'!A1", 1, 0) == "'Q1 costs'!A2"
      assert Formula.translate("'It''s A1'!A1", 1, 0) == "'It''s A1'!A2"
      assert Formula.translate("Sheet1!A1", 1, 0) == "Sheet1!A2"
    end

    test "a function whose name looks like a reference" do
      assert Formula.translate("LOG10(A1)+ATAN2(B1,C1)", 1, 1) == "LOG10(B2)+ATAN2(C2,D2)"
    end

    test "a number in exponent form, and a name with digits in it" do
      assert Formula.translate("1.5E2+Rate2024*A1", 1, 0) == "1.5E2+Rate2024*A2"
    end

    test "a structured reference and the functions that take none" do
      formula = "Table1[Amount]+ROW()+COLUMN()+TRUE+PI()"
      assert Formula.translate(formula, 5, 5) == formula
    end
  end

  describe "as a pair" do
    test "moving there and back is the identity while nothing leaves the sheet" do
      formulas = [
        "A1*2",
        "SUM(B2:D9)/COUNT(B:B)",
        ~s|IF(C3="","",$A$1+A$1+$A1)|,
        "'Q1 costs'!E5+Sheet2!F6",
        "SUM(3:3)+LOG10(G7)"
      ]

      for formula <- formulas, {rows, cols} <- [{1, 1}, {7, 0}, {0, 3}, {2, 2}] do
        moved = Formula.translate(formula, rows, cols)
        assert Formula.translate(moved, -rows, -cols) == formula, "#{formula} by #{rows},#{cols}"
      end
    end
  end
end
