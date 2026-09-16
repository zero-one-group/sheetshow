# Checks the WebDAV store against a real server, which nothing in the test
# suite can do: the tests answer canned responses on localhost, so they prove
# what Sheetshow sends and not what Nextcloud makes of it.
#
# What this cannot be sure of until you run it is the one thing the store is
# for: that the server honours `If-Match` on PUT and answers 412 rather than
# writing anyway. RFC 7232 requires it and SabreDAV implements preconditions,
# but a server sits behind whatever its owner put in front of it.
#
#     export NEXTCLOUD_URL=https://cloud.example.com
#     export NEXTCLOUD_USER=your-username
#     export NEXTCLOUD_APP_PASSWORD=xxxxx-xxxxx-xxxxx-xxxxx-xxxxx
#     mix run dev/webdav.exs
#
# The app password is made under Personal settings → Security → Devices &
# sessions. The account's own password is refused when the account has
# two-factor authentication or signs in through somewhere else.
#
# It writes and then deletes `sheetshow-check-<n>.xlsx` in the account's root,
# and touches nothing else.

alias Sheetshow.{Op, Store, Workbook}

defmodule Check do
  def step(what, fun) do
    IO.write(String.pad_trailing(what, 52))

    case fun.() do
      {:ok, said} ->
        IO.puts("ok   #{said}")
        :ok

      {:error, why} ->
        IO.puts("FAILED\n\n  #{why}\n")
        System.halt(1)
    end
  end
end

url = System.get_env("NEXTCLOUD_URL") || raise "set NEXTCLOUD_URL"
user = System.get_env("NEXTCLOUD_USER") || raise "set NEXTCLOUD_USER"
password = System.get_env("NEXTCLOUD_APP_PASSWORD") || raise "set NEXTCLOUD_APP_PASSWORD"

name = "sheetshow-check-#{System.unique_integer([:positive])}.xlsx"
store = Store.nextcloud(url, user, name, password: password)

IO.puts("\n#{store.location}\n")

workbook = Workbook.xlsx(store, create: true)

cells =
  Sheetshow.stack([
    Sheetshow.row(["Item", "Cost"], style: %{bold: true}),
    Sheetshow.rows([["Rent", 1000], ["Food", 400]])
  ])
  |> Sheetshow.put_sheet("Costs")

Check.step("the file is not there yet", fn ->
  case Store.read(store) do
    {:error, %{reason: :not_found}} ->
      {:ok, ""}

    {:error, %{reason: :http, details: %{status: 401}} = error} ->
      {:error, Exception.message(error)}

    {:ok, {_bytes, _version}} ->
      {:error, "something is already at that name"}

    {:error, error} ->
      {:error, Exception.message(error)}
  end
end)

Check.step("creating it writes a workbook", fn ->
  with {:ok, connected} <- Sheetshow.connect(workbook),
       plan = Sheetshow.plan!(cells, existing_sheets: Map.keys(connected.sheets)),
       {:ok, _} <- Sheetshow.run(plan, connected) do
    {:ok, ""}
  else
    {:error, error} -> {:error, Exception.message(error)}
  end
end)

Check.step("reading it back gives what went in", fn ->
  case Sheetshow.read_rows("Costs", workbook) do
    {:ok, [["Item", "Cost"] | _] = rows} -> {:ok, "#{length(rows)} rows"}
    {:ok, other} -> {:error, "got #{inspect(other)}"}
    {:error, error} -> {:error, Exception.message(error)}
  end
end)

Check.step("the read carries an entity tag", fn ->
  case Store.read(store) do
    {:ok, {_bytes, :unknown}} ->
      {:error, "the server sent no ETag, so a conditional write is not possible"}

    {:ok, {_bytes, "W/" <> _ = weak}} ->
      {:error,
       "the server sent a weak entity tag (#{weak}), which If-Match can never match. " <>
         "Something in front of it is compressing the response; turn that off for this path."}

    {:ok, {_bytes, etag}} ->
      {:ok, etag}
  end
end)

{:ok, {_bytes, version}} = Store.read(store)

Check.step("appending a row works with that tag", fn ->
  row = Sheetshow.row(["Bus", 50], sheet: "Costs")

  case Sheetshow.run([Op.AppendRows.new(row)], workbook) do
    {:ok, _} -> {:ok, ""}
    {:error, error} -> {:error, Exception.message(error)}
  end
end)

Check.step("and a stale tag is refused rather than written", fn ->
  # `version` is what the file was at before the append above, so the server
  # should now refuse it. This is the whole point of the store.
  case Store.write(store, "not a workbook at all", version) do
    {:error, %{reason: :conflict}} ->
      {:ok, "412, as it should be"}

    {:ok, _} ->
      {:error,
       "the server took a write whose If-Match was stale. It is not honouring preconditions, " <>
         "so this store cannot promise a conditional write against it."}

    {:error, error} ->
      {:error, Exception.message(error)}
  end
end)

Check.step("the file still holds what it should", fn ->
  case Sheetshow.read_rows("Costs", workbook) do
    {:ok, rows} ->
      if List.last(rows) == ["Bus", 50],
        do: {:ok, "#{length(rows)} rows"},
        else: {:error, "the refused write got through: #{inspect(rows)}"}

    {:error, error} ->
      {:error, Exception.message(error)}
  end
end)

Check.step("cleaning up", fn ->
  headers = [{"authorization", "Basic " <> Base.encode64("#{user}:#{password}")}]

  case Sheetshow.HTTP.request(:delete, store.location, headers) do
    {:ok, %{status: status}} when status in 200..299 -> {:ok, ""}
    {:ok, %{status: status}} -> {:error, "the server answered #{status}; delete #{name} yourself"}
    {:error, error} -> {:error, Exception.message(error)}
  end
end)

IO.puts("\nEverything this store promises, that server keeps.\n")
