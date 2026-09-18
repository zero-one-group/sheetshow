defmodule Sheetshow.Store.LocalTest do
  use ExUnit.Case, async: true

  doctest Sheetshow.Store

  alias Sheetshow.{Error, Store}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheetshow-#{System.unique_integer([:positive])}/costs.xlsx"
      )

    on_exit(fn -> path |> Path.dirname() |> File.rm_rf() end)
    %{store: Store.local(path), path: path}
  end

  describe "reading" do
    test "gives back the bytes and a version", %{store: store, path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "hello")

      assert {:ok, {"hello", version}} = Store.read(store)
      refute version == :absent
    end

    test "a file that is not there is its own reason, not a failure", %{store: store} do
      assert {:error, %Error{reason: :not_found} = error} = Store.read(store)
      assert Exception.message(error) =~ "there is nothing at"
    end

    test "and every other way a read can fail is still one", %{store: store, path: path} do
      # A directory where the file should be: there is something there, and it
      # is not a file we can read.
      File.mkdir_p!(path)

      assert {:error, %Error{reason: :io} = error} = Store.read(store)
      assert error.details.posix == :eisdir
    end

    test "exists? answers without reading", %{store: store, path: path} do
      refute Store.exists?(store)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "x")
      assert Store.exists?(store)
    end
  end

  describe "writing" do
    test "makes the directory it needs", %{store: store, path: path} do
      assert {:ok, _version} = Store.write(store, "hello")
      assert File.read!(path) == "hello"
    end

    test "gives back the version it is now at", %{store: store} do
      assert {:ok, first} = Store.write(store, "one")
      assert {:ok, {"one", ^first}} = Store.read(store)
    end

    test "leaves nothing behind when it is done", %{store: store, path: path} do
      {:ok, _} = Store.write(store, "hello")

      assert path |> Path.dirname() |> File.ls!() == ["costs.xlsx"]
    end

    test "a version that still holds is written", %{store: store} do
      {:ok, _} = Store.write(store, "one")
      {:ok, {_bytes, version}} = Store.read(store)

      assert {:ok, _} = Store.write(store, "two", version)
      assert {:ok, {"two", _}} = Store.read(store)
    end

    test "a version that no longer holds is refused rather than carried out", %{store: store} do
      {:ok, _} = Store.write(store, "one")
      {:ok, {_bytes, stale}} = Store.read(store)

      # Somebody else, in between.
      {:ok, _} = Store.write(store, "a longer thing entirely")

      assert {:error, %Error{reason: :conflict} = error} = Store.write(store, "two", stale)
      assert Exception.message(error) =~ "has changed since it was read"
      assert {:ok, {"a longer thing entirely", _}} = Store.read(store)
    end

    test "a file that has gone since it was read", %{store: store, path: path} do
      {:ok, _} = Store.write(store, "one")
      {:ok, {_bytes, version}} = Store.read(store)
      File.rm!(path)

      assert {:error, %Error{reason: :conflict} = error} = Store.write(store, "two", version)
      assert Exception.message(error) =~ "has been removed"
    end

    test "creating a file somebody else created first", %{store: store} do
      # `:absent` is the version of a file that is not there, which is what a
      # write meaning to create one insists is still true.
      {:ok, _} = Store.write(store, "theirs")

      assert {:error, %Error{reason: :conflict} = error} = Store.write(store, "ours", :absent)
      assert Exception.message(error) =~ "created by somebody else"
    end

    test "creating one nobody else did", %{store: store} do
      assert {:ok, _} = Store.write(store, "ours", :absent)
      assert {:ok, {"ours", _}} = Store.read(store)
    end

    test "and the version a read of a file that is not there would have given is :absent",
         %{store: store, path: path} do
      # Not observable through `read/1`, which answers `:not_found` instead, so
      # it is the write path that has to agree about what absence looks like.
      refute File.exists?(path)

      assert {:ok, _} = Store.write(store, "ours", :absent)
      assert {:error, %Error{reason: :conflict}} = Store.write(store, "again", :absent)
    end

    test ":any writes over whatever is there", %{store: store} do
      {:ok, _} = Store.write(store, "one")
      assert {:ok, _} = Store.write(store, "two", :any)
      assert {:ok, {"two", _}} = Store.read(store)
    end
  end

  describe "what it can promise" do
    test "not a conditional write: looking and writing are two moments", %{store: store} do
      refute Store.conditional_write?(store)
    end

    test "and a workbook over it says so", %{store: store} do
      workbook = Sheetshow.Workbook.xlsx(store)

      refute Sheetshow.Backend.supports?(workbook, :conditional_write)
      assert Sheetshow.Backend.supports?(workbook, :atomic_batch)
      refute Sheetshow.Backend.supports?(workbook, :evaluates_formulas)
      refute Sheetshow.Backend.supports?(workbook, :server_side_append)
    end
  end

  describe "permissions" do
    test "a write over a private file keeps it private", %{store: store, path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "old")
      File.chmod!(path, 0o600)

      assert {:ok, _version} = Store.write(store, "new", :any)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test "a new file is created private, not with the process umask", %{store: store, path: path} do
      assert {:ok, _version} = Store.write(store, "new", :any)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test "a successful write leaves no temporary file behind", %{store: store, path: path} do
      assert {:ok, _version} = Store.write(store, "new", :any)
      assert Path.dirname(path) |> File.ls!() |> Enum.reject(&(&1 == "costs.xlsx")) == []
    end

    test "a refused write leaves the file untouched and no temporary behind", %{
      store: store,
      path: path
    } do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "old")

      # The precondition names a version the file does not have, so the write is
      # refused: the original stands and nothing is left in the directory.
      assert {:error, %Error{reason: :conflict}} = Store.write(store, "new", {999, 0})
      assert File.read!(path) == "old"
      assert Path.dirname(path) |> File.ls!() |> Enum.reject(&(&1 == "costs.xlsx")) == []
    end
  end

  describe "the value" do
    test "names the module that does the work and where the file is" do
      store = Store.local("costs.xlsx")

      assert store.module == Sheetshow.Store.Local
      assert store.location == "costs.xlsx"
    end
  end
end
