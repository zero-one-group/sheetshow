defmodule Sheetshow.Workbook do
  @moduledoc """
  Which spreadsheet, and which backend reaches it.

  A workbook is the value every impure function takes and gives back. It names
  a backend module, holds whatever that backend needs to find the spreadsheet,
  and remembers the sheets it has.

      iex> workbook = Sheetshow.Workbook.memory(["Costs"])
      iex> workbook.backend
      Sheetshow.Memory.Backend
      iex> Map.keys(workbook.sheets)
      ["Costs"]

  `sheets` maps each sheet's title to whatever the backend calls it: the number
  Google knows it by, `nil` where the backend has no name of its own.
  `Sheetshow.plan/2` wants the keys for `:existing_sheets`, and the Google wire
  format needs the values to address a cell.

  `ref` is the backend's own handle: a `Sheetshow.Client` for Google, a
  `Sheetshow.Memory` for the in-memory backend. `meta` is the backend's
  scratch, and both of the backends here leave it empty.
  """

  alias Sheetshow.{Client, Memory, Store}

  @enforce_keys [:backend, :ref]
  defstruct [:backend, :ref, sheets: %{}, meta: %{}]

  @type t :: %__MODULE__{
          backend: module(),
          ref: term(),
          sheets: %{String.t() => term()},
          meta: map()
        }

  @doc """
  A workbook over one Google spreadsheet.

  Takes a spreadsheet id and the options `Sheetshow.Client.new/2` takes, or a
  client you have already built, which carries its options already, so none
  are taken with it. It knows no sheets until `Sheetshow.connect/1`.

      iex> workbook = Sheetshow.Workbook.google("1AbC")
      iex> workbook.ref.spreadsheet_id
      "1AbC"
      iex> workbook.sheets
      %{}
  """
  @spec google(String.t() | Client.t(), keyword()) :: t()
  def google(spreadsheet_or_client, opts \\ [])

  def google(%Client{} = client, []) do
    %__MODULE__{backend: Sheetshow.Google.Backend, ref: client}
  end

  def google(%Client{}, opts) when is_list(opts) do
    raise ArgumentError,
          "a client carries its own options; pass #{inspect(opts)} to Sheetshow.Client.new/2"
  end

  def google(spreadsheet_id, opts) when is_binary(spreadsheet_id) do
    google(Client.new(spreadsheet_id, opts), [])
  end

  @doc """
  A workbook over a `Sheetshow.Memory`: the spreadsheet that needs no network.

  Takes the titles of the sheets to start with, or a memory you already hold.

      iex> Sheetshow.Workbook.memory() |> Sheetshow.Workbook.titles()
      []
  """
  @spec memory(Memory.t() | [String.t()]) :: t()
  def memory(titles_or_memory \\ [])

  def memory(titles) when is_list(titles), do: memory(Memory.new(titles))

  def memory(%Memory{} = memory) do
    %__MODULE__{backend: Sheetshow.Memory.Backend, ref: memory, sheets: sheets(memory)}
  end

  @doc """
  A workbook over an `.xlsx` file.

  Takes a path, or a `Sheetshow.Store` saying where the file is and how to
  reach it. `create: true` says a file that is not there yet is an empty
  workbook to be written rather than a mistake.

      iex> workbook = Sheetshow.Workbook.xlsx("costs.xlsx")
      iex> {workbook.backend, workbook.ref.location}
      {Sheetshow.Xlsx.Backend, "costs.xlsx"}
  """
  @spec xlsx(Path.t() | Store.t(), keyword()) :: t()
  def xlsx(location, opts \\ [])

  def xlsx(%Store{} = store, opts) do
    opts = Keyword.validate!(opts, create: false)

    %__MODULE__{
      backend: Sheetshow.Xlsx.Backend,
      ref: store,
      meta: %{create: Keyword.fetch!(opts, :create)}
    }
  end

  def xlsx(path, opts) when is_binary(path), do: xlsx(Store.local(path), opts)

  @doc """
  The sheet titles the workbook knows about, sorted.

      iex> Sheetshow.Workbook.memory(["log", "Costs"]) |> Sheetshow.Workbook.titles()
      ["Costs", "log"]
  """
  @spec titles(t()) :: [String.t()]
  def titles(%__MODULE__{sheets: sheets}), do: sheets |> Map.keys() |> Enum.sort()

  @doc false
  @spec put_sheets(t(), %{String.t() => term()}) :: t()
  def put_sheets(%__MODULE__{} = workbook, sheets) when is_map(sheets) do
    %{workbook | sheets: sheets}
  end

  @doc false
  @spec put_ref(t(), term()) :: t()
  def put_ref(%__MODULE__{} = workbook, ref), do: %{workbook | ref: ref}

  defp sheets(%Memory{} = memory), do: Map.new(Memory.titles(memory), &{&1, nil})
end
