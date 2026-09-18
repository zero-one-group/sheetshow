defmodule Sheetshow.Store.Local do
  @moduledoc """
  A spreadsheet file on the machine this is running on.

  Writes go to a temporary file beside the real one and are moved into place
  with a rename, which on every filesystem Erlang runs on is atomic: a reader
  opening the file while it is being written sees the old one whole or the new
  one whole, never half of either.

  ## What it cannot promise

  A conditional write. The version here is the file's size and modification
  time, which is checked immediately before the rename, so a write that would
  clobber somebody is usually refused rather than silently carried out. But
  "immediately before" is not "at the same instant as", and the modification
  time a filesystem keeps has one-second resolution, so two writes of the same
  size in the same second are indistinguishable.

  It is a guard, not a guarantee, and `Sheetshow.Backend.supports?(workbook,
  :conditional_write)` answers `false` for it accordingly. A store that can do
  better, one that speaks `If-Match`, is what closes that gap.
  """

  @behaviour Sheetshow.Store

  alias Sheetshow.{Error, Store}

  @impl true
  def read(%Store{location: path}) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, {bytes, version(path)}}

      {:error, :enoent} ->
        {:error, Error.new(:not_found, "there is nothing at #{path}", path: path)}

      {:error, reason} ->
        {:error,
         Error.new(:io, "could not read #{path}: #{:file.format_error(reason)}",
           path: path,
           posix: reason
         )}
    end
  end

  @impl true
  def write(%Store{location: path} = store, bytes, precondition) do
    with :ok <- check(store, precondition),
         :ok <- mkdir(path),
         {:ok, temporary} <- write_temporary(path, bytes) do
      finish(store, path, temporary, precondition)
    end
  end

  # Once the temporary file exists it must not be left behind, whatever goes
  # wrong: mode, a lost race, or the rename itself. On success the rename has
  # already moved it, so there is nothing to clean up.
  defp finish(store, path, temporary, precondition) do
    with :ok <- preserve_mode(path, temporary),
         :ok <- check(store, precondition),
         :ok <- rename(temporary, path) do
      {:ok, version(path)}
    else
      error ->
        File.rm(temporary)
        error
    end
  end

  @impl true
  def exists?(%Store{location: path}), do: File.regular?(path)

  # Checking and then writing is not the same as writing conditionally, and
  # saying otherwise would let a caller build on a promise nothing here keeps.
  @impl true
  def conditional_write?(%Store{}), do: false

  defp check(%Store{}, :any), do: :ok

  defp check(%Store{location: path} = store, expected) do
    case {version(path), expected} do
      {same, same} ->
        :ok

      {:absent, _} ->
        {:error, Store.conflict(store, "#{path} has been removed since it was read")}

      # A write meaning to create the file finds somebody got there first.
      {_now, :absent} ->
        {:error, Store.conflict(store, "#{path} was created by somebody else since we looked")}

      _ ->
        {:error, Store.conflict(store, "#{path} has changed since it was read")}
    end
  end

  # Size and modification time: enough to notice that somebody else has written
  # the file, and not enough to be sure they have not. A file that is not there
  # has no size and no modification time, and `:absent` is the version of that.
  defp version(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime}} -> {size, mtime}
      {:error, _} -> :absent
    end
  end

  defp mkdir(path) do
    case path |> Path.dirname() |> File.mkdir_p() do
      :ok -> :ok
      {:error, reason} -> {:error, io(path, "could not make the directory for", reason)}
    end
  end

  # Beside the real file rather than in a temporary directory, because a rename
  # is only atomic within one filesystem and /tmp is often another one.
  #
  # The file is created exclusively (`:exclusive` is `O_CREAT | O_EXCL`, so two
  # writers cannot pick the same name and clobber each other) and made 0600 while
  # it is still empty; only then are the bytes written into it. That order is the
  # point: the sensitive bytes never sit in a file readable at the process umask,
  # so there is no window for an observer on a traversable directory to read them.
  # `preserve_mode/2` sets the final mode from the destination just before the
  # rename.
  defp write_temporary(path, bytes) do
    temporary = "#{path}.sheetshow-#{System.unique_integer([:positive])}"

    with {:ok, device} <- open_private(temporary),
         :ok <- write_bytes(temporary, device, bytes) do
      {:ok, temporary}
    end
  end

  defp open_private(temporary) do
    case File.open(temporary, [:write, :binary, :exclusive]) do
      {:ok, device} ->
        case File.chmod(temporary, 0o600) do
          :ok ->
            {:ok, device}

          {:error, reason} ->
            File.close(device)
            File.rm(temporary)
            {:error, io(temporary, "could not set the permissions on", reason)}
        end

      {:error, reason} ->
        {:error, io(temporary, "could not create", reason)}
    end
  end

  defp write_bytes(temporary, device, bytes) do
    # `:file.write/2` rather than `IO.binwrite/2`: the latter's typespec says it
    # only ever returns `:ok`, so matching its error would be flagged as dead.
    result = :file.write(device, bytes)
    File.close(device)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(temporary)
        {:error, io(temporary, "could not write", reason)}
    end
  end

  # A write replaces a file's contents, not its access mode: a file somebody
  # made private (0600) stays private, rather than picking up whatever the
  # process umask allows. A file being created keeps the temporary's own 0600,
  # which is the safe default when there is no destination mode to match.
  defp preserve_mode(path, temporary) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        case File.chmod(temporary, Bitwise.band(mode, 0o7777)) do
          :ok -> :ok
          {:error, reason} -> {:error, io(temporary, "could not set the permissions on", reason)}
        end

      {:error, _absent} ->
        :ok
    end
  end

  # Cleanup of the temporary file on failure is `finish/4`'s job, so this only
  # renames and reports.
  defp rename(temporary, path) do
    case File.rename(temporary, path) do
      :ok -> :ok
      {:error, reason} -> {:error, io(path, "could not move the new file into place at", reason)}
    end
  end

  defp io(path, what, reason) do
    Error.new(:io, "#{what} #{path}: #{:file.format_error(reason)}", path: path, posix: reason)
  end
end
