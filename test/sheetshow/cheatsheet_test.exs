defmodule Sheetshow.CheatsheetTest do
  use ExUnit.Case, async: true

  # `guides/cheatsheet.cheatmd` is generated and checked in, so it goes stale the
  # moment a function is added, renamed, or has the first line of its doc
  # rewritten. This regenerates the page and diffs it, rather than deriving a
  # second time what the page ought to say: one generator, two callers.

  # `dev/` is not compiled with the tests; the generator is required in
  # `setup_all`, so the compiler is told not to warn that it cannot see it.
  @compile {:no_warn_undefined, Sheetshow.Dev.Cheatsheet}

  @generator "dev/cheatsheet.exs"

  setup_all do
    Code.require_file(@generator)
    :ok
  end

  test "the checked-in cheatsheet is what the generator produces now" do
    path = Sheetshow.Dev.Cheatsheet.output()

    assert File.exists?(path), "#{path} is missing; run `mix run #{@generator} --write`"

    assert File.read!(path) == Sheetshow.Dev.Cheatsheet.render(),
           "#{path} is stale; run `mix run #{@generator} --write` and commit the result"
  end

  # The diff above would pass on an empty page, since the file would match it.
  test "and it still has a corpus" do
    lines = Sheetshow.Dev.Cheatsheet.render() |> String.split("\n")

    entries = Enum.count(lines, &String.starts_with?(&1, "| `"))
    cards = Enum.count(lines, &String.starts_with?(&1, "### "))

    assert entries >= 150, "cheatsheet entries fell to #{entries}"
    assert cards >= 30, "cheatsheet cards fell to #{cards}"
  end

  # Every row is a table cell, and a table cell cannot wrap, so the generator
  # clamps each summary to fit. If that stops working the page still renders,
  # badly, which is the kind of defect a gate should carry rather than a reader.
  test "no line is wider than the repository's 98 columns" do
    over =
      Sheetshow.Dev.Cheatsheet.render()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} -> String.length(line) > 98 end)

    assert over == []
  end

  # The diff compares the generator with its own output, so a bug in the
  # generator sits on both sides of that assertion. These two functions are pure
  # over a string, so they are checked against expectations written by hand.

  describe "first_sentence/1" do
    test "returns a summary with no sentence break as it stands" do
      text = "Every cell in the range, in reading order"

      assert Sheetshow.Dev.Cheatsheet.first_sentence(text) == text
    end

    test "drops the second sentence and closes the cut with one full stop" do
      assert Sheetshow.Dev.Cheatsheet.first_sentence("The first one. The second one.") ==
               "The first one."
    end

    test "keeps an example in the first sentence, `e.g.` and all" do
      text = "The number format a date is given, e.g. `yyyy-mm-dd`."

      assert Sheetshow.Dev.Cheatsheet.first_sentence(text) == text
    end

    test "does not end the sentence at an abbreviation inside it" do
      assert Sheetshow.Dev.Cheatsheet.first_sentence("A run, i.e. one PutCells. The next one.") ==
               "A run, i.e. one PutCells."
    end
  end

  describe "row/3" do
    test "marks a function that has a raising twin" do
      row = Sheetshow.Dev.Cheatsheet.row("plan/2", "Turns cells into a plan.", true)

      assert String.ends_with?(row, "| Turns cells into a plan. **+ !** |")
    end

    test "keeps the marker on a summary long enough to clamp" do
      row = Sheetshow.Dev.Cheatsheet.row("plan/2", long_summary(), true)

      assert row =~ "…"
      assert String.ends_with?(row, "**+ !** |")
    end

    test "clamps a summary with no twin and leaves it unmarked" do
      row = Sheetshow.Dev.Cheatsheet.row("plan/2", long_summary(), false)

      assert row =~ "…"
      refute row =~ "**+ !**"
    end

    test "fits the generator's width, marker and all" do
      for twin? <- [true, false], call <- ["plan/2", "default_number_format/1"] do
        assert String.length(Sheetshow.Dev.Cheatsheet.row(call, long_summary(), twin?)) <= 98
      end
    end
  end

  # Longer than any budget `row/3` computes, so it clamps for either call name.
  defp long_summary do
    "Turns the cells into " <>
      String.duplicate("a plan and then some more of it ", 6) <> "at last."
  end
end
