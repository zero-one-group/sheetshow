# Generates `guides/cheatsheet.cheatmd`, ExDoc's cheatsheet format, from the
# compiled modules, so that the page cannot say something the code does not.
#
#     mix run dev/cheatsheet.exs --write
#
# Without `--write` it only defines `Sheetshow.Dev.Cheatsheet`, which
# `test/sheetshow/cheatsheet_test.exs` uses to regenerate the page and diff it
# against the file. The sections are `mix.exs`'s `:groups_for_modules`, one card
# per module, one row per public function with the first sentence of its doc;
# a behaviour's callbacks get a card of their own.

defmodule Sheetshow.Dev.Cheatsheet do
  @moduledoc false

  @output "guides/cheatsheet.cheatmd"

  def output, do: @output

  def render do
    [preamble() | Enum.map(groups(), &group/1)]
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  def write do
    File.write!(@output, render())
    IO.puts("wrote #{@output} (#{length(String.split(render(), "\n"))} lines)")
  end

  defp preamble do
    """
    # Cheatsheet

    Every public function, one line each, generated from the compiled modules by
    `dev/cheatsheet.exs`; `test/sheetshow/cheatsheet_test.exs` fails if it drifts.
    **`+ !`** marks a function with a raising twin of the same arity. The sections
    are the sidebar's.
    """
  end

  defp groups,
    do: Mix.Project.config() |> Keyword.fetch!(:docs) |> Keyword.fetch!(:groups_for_modules)

  defp group({title, modules}) do
    cards = modules |> Enum.flat_map(&cards/1) |> Enum.join("\n")

    "## #{title}\n\n" <> cards
  end

  # A module with no public functions, such as a struct and its type, has no card.
  defp cards(module) do
    {functions, callbacks} = entries(module)

    [card(inspect(module), functions), card("#{inspect(module)}: callbacks", callbacks)]
    |> Enum.reject(&is_nil/1)
  end

  defp card(_title, []), do: nil

  defp card(title, entries) do
    rows =
      entries
      |> Enum.sort_by(fn {name, _arities, _summary, _twin?} -> to_string(name) end)
      |> Enum.map_join("\n", fn {name, arities, summary, twin?} ->
        row("#{name}#{arities}", summary, twin?)
      end)

    "### #{title}\n\n| | |\n| --- | --- |\n#{rows}\n"
  end

  # `{name, "/2,3", summary, twin?}` per public function and per callback, with
  # the `!` twins folded into the entry they raise for: a twin's own docstring
  # is "Same as `x/2`, raising on failure", which nobody needs a row for.
  defp entries(module) do
    {:docs_v1, _anno, _lang, _format, _moduledoc, _meta, docs} = Code.fetch_docs(module)

    public =
      for {{kind, name, arity}, _line, _signature, %{"en" => doc}, _meta} <- docs,
          kind in [:function, :callback],
          do: {kind, name, arity, doc}

    bangs =
      for {:function, name, arity, _doc} <- public,
          String.ends_with?(to_string(name), "!"),
          into: MapSet.new(),
          do: {String.trim_trailing(to_string(name), "!"), arity}

    grouped =
      public
      |> Enum.reject(fn {_kind, name, _arity, _doc} ->
        String.ends_with?(to_string(name), "!")
      end)
      |> Enum.group_by(fn {kind, name, _arity, _doc} -> {kind, name} end)
      |> Enum.map(fn {{kind, name}, clauses} ->
        arities = clauses |> Enum.map(&elem(&1, 2)) |> Enum.sort() |> Enum.uniq()
        {_kind, _name, _arity, doc} = Enum.min_by(clauses, &elem(&1, 2))
        twin? = Enum.any?(arities, &MapSet.member?(bangs, {to_string(name), &1}))

        {kind, {name, "/" <> Enum.join(arities, ","), summary(doc), twin?}}
      end)

    {for({:function, entry} <- grouped, do: entry), for({:callback, entry} <- grouped, do: entry)}
  end

  # A table row cannot wrap, so the summary is cut to fit the repository's 98
  # columns rather than letting a generated file carry over-long lines. An entry
  # that needs more than this is not a cheatsheet entry; the module page is
  # where the sentence belongs.
  @width 98
  @marker " **+ !**"

  # The marker is appended after clamping and its width reserved before, so a
  # long summary loses words rather than the fact that the function has a
  # raising twin. Public, like `first_sentence/1`, only so the test can call it.
  def row(call, text, twin?) do
    fixed = String.length("| `#{call}` |  |")
    budget = @width - fixed - if(twin?, do: String.length(@marker), else: 0)
    "| `#{call}` | #{clamp(text, budget)}#{if twin?, do: @marker, else: ""} |"
  end

  defp clamp(text, budget) do
    if String.length(text) <= budget do
      text
    else
      text
      |> String.split(" ")
      |> Enum.reduce_while([], fn word, taken ->
        candidate = Enum.reverse([word | taken])

        if candidate |> Enum.join(" ") |> String.length() > budget - 1,
          do: {:halt, taken},
          else: {:cont, [word | taken]}
      end)
      |> Enum.reverse()
      |> Enum.join(" ")
      |> String.trim_trailing(",")
      |> Kernel.<>("…")
    end
  end

  # The first sentence of the docstring, which `docs_test.exs` guarantees exists.
  # A summary that wrapped in the source is rejoined, so the cell is one line.
  defp summary(doc) do
    doc
    |> String.split("\n\n", parts: 2)
    |> hd()
    |> String.split("\n")
    |> Enum.map_join(" ", &String.trim/1)
    |> String.trim()
    |> first_sentence()
    |> String.replace("|", "\\|")
  end

  # Splitting on ". " rather than "." keeps `Sheetshow.run` intact. It does not
  # keep `e.g.` intact, since that is `e.g` followed by ". ", so a part ending in an
  # abbreviation is rejoined with the next. A trailing full stop is put back
  # only when something was dropped, since the cut is then the sentence's end.
  @abbreviations ~w(e.g i.e cf vs etc resp)

  def first_sentence(text) do
    parts = String.split(text, ". ")
    taken = take_sentence(parts)
    joined = Enum.join(taken, ". ")

    if length(taken) == length(parts), do: joined, else: joined <> "."
  end

  defp take_sentence([part | rest]) when rest != [] do
    if abbreviation?(part), do: [part | take_sentence(rest)], else: [part]
  end

  defp take_sentence(parts), do: parts

  defp abbreviation?(part) do
    Enum.any?(@abbreviations, &(part == &1 or String.ends_with?(part, " " <> &1)))
  end
end

if "--write" in System.argv(), do: Sheetshow.Dev.Cheatsheet.write()
