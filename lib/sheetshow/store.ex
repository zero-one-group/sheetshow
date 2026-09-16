defmodule Sheetshow.Store do
  @moduledoc """
  Where a spreadsheet file lives, and how to read and write it.

  A file backend is two things that vary on their own: a **format**, which says
  how cells become bytes, and a **store**, which says where those bytes are and
  what it can promise about writing them. `Sheetshow.Xlsx` is the first format;
  `Sheetshow.Store.Local` is the first store.

      workbook = Sheetshow.Workbook.xlsx("costs.xlsx")

  A store is a value, like everything else here: the module that does the work,
  and whatever that module needs to find the file.

      iex> store = Sheetshow.Store.local("costs.xlsx")
      iex> {store.module, store.location}
      {Sheetshow.Store.Local, "costs.xlsx"}

  ## Versions, and what they are for

  `read/1` gives back the bytes and a **version**: whatever the store uses to
  tell one state of the file from another. `write/3` takes that version back as
  a precondition, and a store that can refuse a write whose version no longer
  holds answers `%Sheetshow.Error{reason: :conflict}` instead of overwriting.
  That is `:conditional_write`, and writing a cell to a file replaces the whole
  file, so it matters more here than at Google; see
  [What Sheetshow Can Promise](guides/guarantees.md). Not every store can
  promise it; `Sheetshow.Backend.supports?/2` says which kind a workbook sits on.

  A version is the store's own business, an entity tag here and a size and a
  modification time there, and nothing outside the store reads into it. Two
  atoms are reserved, so that a caller never has to guess what a missing one
  meant:

  | version | what it says |
  | --- | --- |
  | `:absent` | the file is not there. A write given it says *only if it is still not there*, which is what stops two processes both believing they created it. |
  | `:unknown` | the store cannot tell this state of the file from another, so there is nothing to make a precondition out of. Read again, or write with `:any` and take the risk. |

  `write/3` also takes `:any`, which writes over whatever is there.
  """

  alias Sheetshow.Error

  # Options can hold an app password, and a store is a value people pass around
  # and print while working things out.
  @derive {Inspect, except: [:options]}
  @enforce_keys [:module, :location]
  defstruct [:module, :location, options: []]

  @typedoc "What the store uses to tell one state of a file from another."
  @type version :: term()

  @typedoc "A version a write insists is still true, or `:any` for whatever is there."
  @type precondition :: version() | :any

  @type t :: %__MODULE__{module: module(), location: term(), options: keyword()}

  @doc "The bytes, and the version they were at."
  @callback read(t()) :: {:ok, {binary(), version()}} | {:error, Error.t()}

  @doc """
  Writes the bytes, giving back the version they are now at. `:any` writes
  whatever is there; a version writes only if that is still what is there.
  """
  @callback write(t(), binary(), precondition()) :: {:ok, version()} | {:error, Error.t()}

  @doc "Whether the file is there at all."
  @callback exists?(t()) :: boolean()

  @doc "Whether this store can refuse a write whose precondition no longer holds."
  @callback conditional_write?(t()) :: boolean()

  @doc """
  A file on the machine this is running on.

      iex> Sheetshow.Store.local("costs.xlsx").module
      Sheetshow.Store.Local
  """
  @spec local(Path.t()) :: t()
  def local(path) when is_binary(path) do
    %__MODULE__{module: Sheetshow.Store.Local, location: path}
  end

  @doc """
  A file on a WebDAV server: Nextcloud, ownCloud, or anything else that speaks
  it. See `Sheetshow.Store.WebDAV` for the options and for what it can promise
  that a local file cannot.

      iex> Sheetshow.Store.webdav("https://cloud.example.com/x.xlsx", username: "user").module
      Sheetshow.Store.WebDAV
  """
  @spec webdav(String.t(), keyword()) :: t()
  def webdav(url, options \\ []) when is_binary(url) do
    %__MODULE__{module: Sheetshow.Store.WebDAV, location: url, options: options}
  end

  @doc """
  A file in a Nextcloud account, by the path you would see in the web
  interface. The same as `webdav/2` with the URL spelled out for you.

      iex> Sheetshow.Store.nextcloud("https://cloud.example.com", "user", "budget/costs.xlsx").location
      "https://cloud.example.com/remote.php/dav/files/user/budget/costs.xlsx"

  Nextcloud wants an **app password** rather than the account's own whenever the
  account has two-factor authentication or signs in through somewhere else:
  Personal settings, then Security, then Devices & sessions.
  """
  @spec nextcloud(String.t(), String.t(), Path.t(), keyword()) :: t()
  def nextcloud(base_url, username, path, options \\ []) do
    url =
      [
        String.trim_trailing(base_url, "/"),
        "remote.php/dav/files",
        escape(username),
        path |> String.trim_leading("/") |> String.split("/") |> Enum.map_join("/", &escape/1)
      ]
      |> Enum.join("/")

    webdav(url, Keyword.put_new(options, :username, username))
  end

  defp escape(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  @doc """
  The bytes, and the version they were at. A file that is not there is
  `%Sheetshow.Error{reason: :not_found}`, told apart from every other way a
  read can fail so that a caller meaning to create one can carry on.
  """
  @spec read(t()) :: {:ok, {binary(), version()}} | {:error, Error.t()}
  def read(%__MODULE__{module: module} = store), do: module.read(store)

  @doc "Writes the bytes, if the precondition still holds."
  @spec write(t(), binary(), precondition()) :: {:ok, version()} | {:error, Error.t()}
  def write(%__MODULE__{module: module} = store, bytes, version \\ :any) do
    module.write(store, bytes, version)
  end

  @doc "Whether the file is there."
  @spec exists?(t()) :: boolean()
  def exists?(%__MODULE__{module: module} = store), do: module.exists?(store)

  @doc "Whether this store can refuse a write whose precondition no longer holds."
  @spec conditional_write?(t()) :: boolean()
  def conditional_write?(%__MODULE__{module: module} = store),
    do: module.conditional_write?(store)

  @doc false
  @spec conflict(t(), String.t()) :: Error.t()
  def conflict(%__MODULE__{} = store, message) do
    Error.new(:conflict, message, location: store.location, store: store.module)
  end
end
