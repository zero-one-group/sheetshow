defmodule Sheetshow.Guides do
  @moduledoc false
  # Runs a guide: every fenced `elixir` block in the file, in order, in one
  # binding, so the guide's own pattern matches are the assertions. A block that
  # cannot run here, because it reaches a Google account or a server, is
  # preceded in the source by `<!-- guide-test: skip -->`, which the rendered
  # page does not show; the test that runs the guide supplies whatever such a
  # block would have bound.

  @skip "<!-- guide-test: skip -->"

  @doc """
  The runnable `elixir` blocks of a guide, as `{code, line}`, in order. Blocks
  marked to skip are left out.
  """
  @spec blocks(Path.t()) :: [{String.t(), pos_integer()}]
  def blocks(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> collect([], nil)
    |> Enum.reverse()
  end

  @doc """
  Runs the guide from `binding`, giving back the binding it leaves behind. A
  block that raises is reported with the guide's path and the block's line.
  """
  @spec run(Path.t(), keyword()) :: keyword()
  def run(path, binding \\ []) do
    # A guide may define a module to show one, and the guide is run more than
    # once; that is not the redefinition the compiler warns about.
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      run_blocks(path, binding)
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  defp run_blocks(path, binding) do
    Enum.reduce(blocks(path), binding, fn {code, line}, binding ->
      try do
        {_value, binding} = Code.eval_string(code, binding, file: path, line: line)
        binding
      rescue
        exception ->
          reraise(
            RuntimeError,
            "#{path}:#{line}: #{Exception.format(:error, exception, __STACKTRACE__)}",
            __STACKTRACE__
          )
      end
    end)
  end

  @doc "Every relative Markdown link in the file, as `{target, line}`."
  @spec links(Path.t()) :: [{String.t(), pos_integer()}]
  def links(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line} ->
      for [_, target] <- Regex.scan(~r/\]\(([^)\s]+)\)/, text),
          not String.starts_with?(target, ["http://", "https://", "#", "mailto:"]),
          do: {target, line}
    end)
  end

  # Walks the lines: outside a block, watch for the marker and a ```elixir fence;
  # inside one, gather until the closing fence.
  defp collect([], acc, _open), do: acc

  defp collect([{line, number} | rest], acc, nil) do
    cond do
      String.trim(line) == @skip -> skip_next(rest, acc)
      String.trim(line) == "```elixir" -> collect(rest, acc, {number + 1, []})
      true -> collect(rest, acc, nil)
    end
  end

  defp collect([{line, _} | rest], acc, {start, lines}) do
    if String.trim(line) == "```" do
      collect(rest, [{lines |> Enum.reverse() |> Enum.join("\n"), start} | acc], nil)
    else
      collect(rest, acc, {start, [line | lines]})
    end
  end

  # After a skip marker, the next fence is dropped whole.
  defp skip_next([{line, _} | rest], acc) do
    if String.trim(line) == "```elixir" do
      rest
      |> Enum.drop_while(fn {l, _} -> String.trim(l) != "```" end)
      |> Enum.drop(1)
      |> collect(acc, nil)
    else
      skip_next(rest, acc)
    end
  end

  defp skip_next([], acc), do: acc
end
