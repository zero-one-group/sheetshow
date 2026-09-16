defmodule Sheetshow.DocsTest do
  use ExUnit.Case, async: true

  # Documentation as a test rather than a habit: a public function with no doc,
  # a module that never said whether it is public, a module missing from the
  # sidebar, a guide that renders nowhere, or a link that goes nowhere all fail
  # here rather than on HexDocs. `mix.exs`'s `:docs` is hand-maintained, and a
  # hand-maintained list gets a check.

  test "every public function in a documented module has a doc" do
    undocumented =
      Enum.flat_map(modules(), fn module ->
        case Code.fetch_docs(module) do
          {:docs_v1, _, _, _, moduledoc, _, docs} when moduledoc not in [:hidden, :none] ->
            for {{:function, name, arity}, _line, _sig, :none, _meta} <- docs,
                do: "#{inspect(module)}.#{name}/#{arity}"

          _other ->
            []
        end
      end)

    assert undocumented == []
  end

  test "every module says whether it is public, rather than leaving it open" do
    silent =
      for module <- modules(),
          match?({:docs_v1, _, _, _, :none, _, _}, Code.fetch_docs(module)),
          do: inspect(module)

    assert silent == []
  end

  test "every documented module has a place in the sidebar, and every place is real" do
    grouped = Enum.flat_map(docs()[:groups_for_modules], fn {_group, modules} -> modules end)
    documented = Enum.sort(documented_modules())

    assert documented -- grouped == [],
           "not in any `groups_for_modules`: " <> inspect(documented -- grouped)

    assert grouped -- documented == [],
           "grouped but not a documented module: " <> inspect(grouped -- documented)
  end

  # Everything under `guides/` renders, and renders under a heading; the rest of
  # the extras are named here because their order is the sidebar's.
  @prose_extras ["README.md", "usage-rules.md", "CHANGELOG.md", "LICENSE"]

  test "every guide is an extra under a heading, and every extra is a real file" do
    extras = extras()
    guides = "guides/*.{md,cheatmd}" |> Path.wildcard() |> Enum.sort()
    grouped = docs()[:groups_for_extras] |> Enum.flat_map(fn {_group, paths} -> paths end)

    assert guides != [], "guides/ is empty; the wildcard would make this pass vacuously"
    assert guides -- extras == [], "a guide that renders nowhere: " <> inspect(guides -- extras)

    assert guides -- grouped == [],
           "a guide under no heading: " <> inspect(guides -- grouped)

    assert grouped -- extras == [],
           "under a heading but not an extra: " <> inspect(grouped -- extras)

    assert Enum.sort(extras) == Enum.sort(guides ++ @prose_extras),
           "extras and the files on disk disagree: " <>
             inspect(Enum.sort(extras) -- Enum.sort(guides ++ @prose_extras)) <>
             " / " <> inspect(Enum.sort(guides ++ @prose_extras) -- Enum.sort(extras))

    for extra <- extras, do: assert(File.exists?(extra), "`:extras` names #{extra}, not a file")
  end

  test "every guide carries a title the sidebar can show" do
    untitled =
      for path <- Path.wildcard("guides/*.{md,cheatmd}"),
          not (path |> File.read!() |> String.starts_with?("# ")),
          do: path

    assert untitled == []
  end

  # ExDoc resolves a link to an extra by its basename alone, so a path that is
  # wrong in a clone renders fine on HexDocs, and a basename belonging to a
  # different extra retargets silently. Both halves are checked: the path
  # resolves on disk from the file it is in, and ExDoc will pick the file it
  # names. A link whose basename is no extra at all 404s on the published site.
  @exdoc_extensions [".md", ".livemd", ".cheatmd", ".txt", ""]

  test "every relative link in the docs resolves, and to the file it names" do
    by_basename = Map.new(extras(), &{Path.basename(&1), &1})

    problems =
      for source <- extras(),
          {href, line} <- Sheetshow.Guides.links(source),
          problem <- link_problem(source, href, by_basename),
          do: "#{source}:#{line}: (#{href}): #{problem}"

    assert problems == []
  end

  defp link_problem(source, href, by_basename) do
    path = href |> String.split("#") |> hd()
    target = path |> Path.expand(Path.dirname(source)) |> Path.relative_to_cwd()
    resolved = by_basename[Path.basename(path)]

    cond do
      path == "" -> []
      not File.exists?(target) -> ["no such file: #{target}"]
      Path.extname(path) not in @exdoc_extensions -> []
      resolved == target -> []
      resolved != nil -> ["ExDoc matches the basename, so this renders as a link to #{resolved}"]
      true -> ["no extra has this basename, so it 404s on HexDocs"]
    end
  end

  defp docs, do: Keyword.fetch!(Mix.Project.config(), :docs)

  # `{"README.md", title: "Sheetshow"}` is a legal entry, so not every extra is a string.
  defp extras do
    Enum.map(docs()[:extras], fn
      {path, _opts} -> to_string(path)
      path -> to_string(path)
    end)
  end

  defp documented_modules do
    for module <- modules(),
        match?(
          {:docs_v1, _, _, _, doc, _, _} when doc not in [:hidden, :none],
          Code.fetch_docs(module)
        ),
        do: module
  end

  defp modules do
    {:ok, modules} = :application.get_key(:sheetshow, :modules)
    modules
  end
end
