defmodule Sheetshow.Xlsx.Backend do
  @moduledoc false
  # The xlsx codec over a store: `Sheetshow.run/2` and the reads, against a file.
  #
  # A file backend is whole-file read-modify-write, because that is what a file
  # is. What keeps that affordable is doing as little of it as possible: the
  # zip work is flat in the file's size, and only the sheets a plan actually
  # names are turned into cells. A plan touching one tab of a 100 MB workbook
  # parses one tab.

  @behaviour Sheetshow.Backend

  alias Sheetshow.{Error, Memory, Op, Range, Result, Store, Workbook, Xlsx}
  alias Sheetshow.Xlsx.Sheet

  # A file is written whole or not at all, so a plan lands or it does not.
  # Nothing here works a formula out, and an append is a rewrite of the file
  # rather than something a server resolves at the moment it applies, so two
  # writers appending to the same file can lose each other's rows, which is the
  # one place `Sheetshow.Log` is weaker here than at Google. Whether a write can
  # be refused rather than clobber somebody is the store's to say.
  @impl true
  def capabilities(%Workbook{ref: %Store{} = store}) do
    %{
      atomic_batch: true,
      conditional_write: Store.conditional_write?(store),
      dimensions: true,
      evaluates_formulas: false,
      server_side_append: false,
      styles: true
    }
  end

  @impl true
  def connect(%Workbook{} = workbook), do: fetch_sheets(workbook)

  @impl true
  def fetch_sheets(%Workbook{} = workbook) do
    with {:ok, package, _version} <- open(workbook) do
      {:ok, put_titles(workbook, package)}
    end
  end

  @impl true
  def run([], %Workbook{} = workbook), do: {:ok, workbook}

  def run(plan, %Workbook{ref: store} = workbook) when is_list(plan) do
    with {:ok, package, version} <- open(workbook),
         {:ok, package} <- apply_plan(plan, package),
         {:ok, bytes} <- Xlsx.encode(package),
         {:ok, _version} <- Store.write(store, bytes, version) do
      {:ok, put_titles(workbook, package)}
    end
  end

  @impl true
  def read_cells(%Range{} = range, %Workbook{} = workbook) do
    with {:ok, package, _version} <- open(workbook),
         {:ok, memory} <- materialise(package, Memory.new(), [range.sheet]) do
      Memory.read(range, memory)
    end
  end

  # Both reads go through the in-memory backend once the sheets are cells, so
  # the two backends cannot drift apart on what a range means or how a row is
  # padded, which is what `Sheetshow.Schema` relies on when it casts what comes
  # back.
  @impl true
  def read_rows(%Range{} = range, %Workbook{} = workbook) do
    with {:ok, in_memory} <- as_memory(workbook, [range]) do
      Sheetshow.Memory.Backend.read_rows(range, in_memory)
    end
  end

  @impl true
  def read_rows_batch(ranges, %Workbook{} = workbook) when is_list(ranges) do
    with {:ok, in_memory} <- as_memory(workbook, ranges) do
      Sheetshow.Memory.Backend.read_rows_batch(ranges, in_memory)
    end
  end

  # --- the file ---

  # One read, and what it says about a file that is not there decides the rest:
  # asking first and reading second would be two round trips and a gap between
  # them.
  defp open(%Workbook{ref: %Store{} = store} = workbook) do
    case Store.read(store) do
      {:ok, {bytes, version}} ->
        with {:ok, package} <- Xlsx.open(bytes), do: {:ok, package, version}

      {:error, %Error{reason: :not_found}} ->
        if creating?(workbook) do
          # Nothing there yet, and the workbook was built saying that is fine.
          # `:absent` is what the store saw, and that is what the write will
          # insist is still true.
          {:ok, Xlsx.new(), :absent}
        else
          {:error,
           Error.new(
             :not_found,
             "there is no workbook at #{inspect(store.location)}. " <>
               "Sheetshow.Workbook.xlsx(location, create: true) makes one.",
             location: store.location
           )}
        end

      {:error, _} = error ->
        error
    end
  end

  defp creating?(%Workbook{meta: meta}), do: Map.get(meta, :create, false)

  defp put_titles(workbook, package) do
    Workbook.put_sheets(workbook, Map.new(Xlsx.titles(package), &{&1, nil}))
  end

  # --- running a plan ---

  # Ops are applied in the order the plan gives them, because that order is
  # load-bearing: a plan creates a tab before writing to it, and deletes rows
  # last and bottom-up so the rest of it lands where it meant to.
  defp apply_plan(plan, package) do
    initial = {package, %{}, Memory.new(), MapSet.new()}

    with {:ok, state} <- Result.reduce(plan, initial, &step/2), do: write_back(state)
  end

  defp step(%Op.AddSheet{title: title}, {package, sheets, memory, touched}) do
    with {:ok, package} <- Xlsx.add_sheet(package, title),
         {:ok, sheet} <- Xlsx.sheet(package, title),
         {:ok, memory} <- Memory.run([Op.AddSheet.new(title)], memory) do
      {:ok, {package, Map.put(sheets, title, sheet), memory, touched}}
    end
  end

  defp step(%Op.DeleteSheet{title: title}, {package, sheets, memory, touched}) do
    with {:ok, package} <- Xlsx.delete_sheet(package, title) do
      memory =
        case Memory.run([Op.DeleteSheet.new(title)], memory) do
          {:ok, memory} -> memory
          # It was never materialised, so there is nothing here to take out.
          {:error, _} -> memory
        end

      {:ok, {package, Map.delete(sheets, title), memory, MapSet.delete(touched, title)}}
    end
  end

  defp step(op, {package, sheets, memory, touched}) do
    title = Op.sheet(op)

    with {:ok, sheets, memory} <- ensure(package, sheets, memory, title),
         {:ok, memory} <- Memory.run([op], memory) do
      {:ok, {package, sheets, memory, MapSet.put(touched, title)}}
    end
  end

  # A sheet becomes cells the first time an op names it, and not before.
  defp ensure(package, sheets, memory, title) do
    if Map.has_key?(sheets, title) do
      {:ok, sheets, memory}
    else
      with {:ok, sheet} <- Xlsx.sheet(package, title) do
        memory =
          Memory.put_sheet(memory, title, sheet.cells, sheet.col_widths, sheet.row_heights)

        {:ok, Map.put(sheets, title, sheet), memory}
      end
    end
  end

  defp write_back({package, sheets, memory, touched}) do
    Result.reduce(touched, package, fn title, package ->
      %Sheet{} = sheet = Map.fetch!(sheets, title)
      dimensions = Memory.dimensions!(title, memory)

      written = %{
        sheet
        | cells: Memory.read!(%Range{sheet: title}, memory),
          col_widths: dimensions.col_widths,
          row_heights: dimensions.row_heights
      }

      Xlsx.put_sheet(package, title, written)
    end)
  end

  # --- reading ---

  # One read of the file, whatever the ranges name, and only the sheets they
  # name turned into cells.
  defp as_memory(%Workbook{} = workbook, ranges) do
    titles = ranges |> Enum.map(& &1.sheet) |> Enum.uniq()

    with {:ok, package, _version} <- open(workbook),
         {:ok, memory} <- materialise(package, Memory.new(), titles) do
      {:ok, Workbook.memory(memory)}
    end
  end

  defp materialise(package, memory, titles) do
    Result.reduce(titles, memory, fn title, memory ->
      with {:ok, sheet} <- Xlsx.sheet(package, title) do
        {:ok, Memory.put_sheet(memory, title, sheet.cells, sheet.col_widths, sheet.row_heights)}
      end
    end)
  end
end
