defmodule Sheetshow.Store.WebDAVTest do
  use ExUnit.Case, async: true

  alias Sheetshow.{Error, Store, TestServer, Workbook}

  defp store(responses, options \\ []) do
    url = TestServer.start(responses)

    Store.webdav(
      url <> "/costs.xlsx",
      Keyword.merge([username: "user", password: "app-pw"], options)
    )
  end

  defp ok(body, headers), do: {200, body, "application/octet-stream", headers}

  describe "reading" do
    test "brings back the bytes and the entity tag" do
      store = store([ok("the bytes", [{"etag", ~s("abc123")}])])

      assert {:ok, {"the bytes", ~s("abc123")}} = Store.read(store)
    end

    test "asks for an identity encoding, so the tag comes back strong" do
      store = store([ok("x", [{"etag", ~s("a")}])])
      {:ok, {_, _}} = Store.read(store)

      assert_receive {:request, request}
      assert request.method == :GET
      assert request.headers["accept-encoding"] == "identity"
    end

    test "signs in with basic auth" do
      store = store([ok("x", [{"etag", ~s("a")}])])
      {:ok, {_, _}} = Store.read(store)

      assert_receive {:request, request}
      assert request.headers["authorization"] == "Basic " <> Base.encode64("user:app-pw")
    end

    test "falls back to Nextcloud's own header when there is no standard one" do
      store = store([ok("x", [{"oc-etag", ~s("nc-1")}])])

      assert {:ok, {"x", ~s("nc-1")}} = Store.read(store)
    end

    test "prefers the standard header, which is the one If-Match compares against" do
      store = store([ok("x", [{"etag", ~s("standard")}, {"oc-etag", ~s("nextclouds")}])])

      assert {:ok, {"x", ~s("standard")}} = Store.read(store)
    end

    test "a file that is not there is its own reason, not a failure" do
      store = store([{404, "", "text/plain", []}])

      assert {:error, %Error{reason: :not_found} = error} = Store.read(store)
      assert Exception.message(error) =~ "there is nothing at"
    end

    test "credentials that are refused say what Nextcloud actually wants" do
      store = store([{401, "", "text/plain", []}])

      assert {:error, %Error{reason: :http} = error} = Store.read(store)
      assert Exception.message(error) =~ "app password"
      assert error.details.status == 401
    end

    test "a server that is not there is a transport error, not a status" do
      store = Store.webdav("http://127.0.0.1:1/costs.xlsx", username: "a", password: "b")

      assert {:error, %Error{reason: :transport}} = Store.read(store)
    end
  end

  describe "writing" do
    test "with a version sends it back as If-Match" do
      store = store([ok("", [{"etag", ~s("new")}])])

      assert {:ok, ~s("new")} = Store.write(store, "bytes", ~s("old"))

      assert_receive {:request, request}
      assert request.method == :PUT
      assert request.headers["if-match"] == ~s("old")
      assert request.body == "bytes"
    end

    test "meaning to create sends If-None-Match, so two creators cannot both win" do
      store = store([ok("", [{"etag", ~s("new")}])])

      assert {:ok, _} = Store.write(store, "bytes", :absent)

      assert_receive {:request, request}
      assert request.headers["if-none-match"] == "*"
      refute Map.has_key?(request.headers, "if-match")
    end

    test ":any sends no precondition at all" do
      store = store([ok("", [{"etag", ~s("new")}])])

      assert {:ok, _} = Store.write(store, "bytes", :any)

      assert_receive {:request, request}
      refute Map.has_key?(request.headers, "if-match")
      refute Map.has_key?(request.headers, "if-none-match")
    end

    test "sends the spreadsheet's own content type" do
      store = store([ok("", [{"etag", ~s("new")}])])
      {:ok, _} = Store.write(store, "bytes", :any)

      assert_receive {:request, request}
      assert request.headers["content-type"] =~ "spreadsheetml.sheet"
    end

    test "a precondition the server refuses is a conflict, and nothing was written" do
      store = store([{412, "", "text/plain", []}])

      assert {:error, %Error{reason: :conflict} = error} = Store.write(store, "bytes", ~s("old"))
      assert Exception.message(error) =~ "has changed since it was read"
    end

    test "and a failed creation says so in its own words" do
      store = store([{412, "", "text/plain", []}])

      assert {:error, %Error{reason: :conflict} = error} = Store.write(store, "bytes", :absent)
      assert Exception.message(error) =~ "has changed since it was to be created"
    end

    test "a server that answers 409 to the same thing means the same thing" do
      store = store([{409, "", "text/plain", []}])

      assert {:error, %Error{reason: :conflict}} = Store.write(store, "bytes", :absent)
    end

    test "a lock, a refusal and a full disk each say which they are" do
      for {status, said} <- [{423, "locked"}, {403, "not allowed to write"}, {507, "out of room"}] do
        store = store([{status, "", "text/plain", []}])

        assert {:error, %Error{reason: :http} = error} = Store.write(store, "bytes", :any)
        assert Exception.message(error) =~ said
      end
    end

    test "a write that answers without a tag leaves the version :unknown" do
      # A separate HEAD could fetch a tag, but another writer racing in between
      # the PUT and the HEAD would have us adopt theirs as if it named our own
      # bytes, and a later conditional write would overwrite what we never read.
      # :unknown is the honest answer, and no HEAD is made.
      store = store([ok("", [])])

      assert {:ok, :unknown} = Store.write(store, "bytes", :any)

      assert_receive {:request, %{method: :PUT}}
      refute_receive {:request, %{method: :HEAD}}, 100
    end
  end

  describe "a version the server never gave" do
    test "a read of a server that sends no entity tag is :unknown, not nil" do
      store = store([ok("the bytes", [])])

      assert {:ok, {"the bytes", :unknown}} = Store.read(store)
    end

    test "and writing against it is refused here, rather than called conditional" do
      store = store([ok("", [{"etag", ~s("new")}])])

      assert {:error, %Error{reason: :unsupported} = error} = Store.write(store, "x", :unknown)
      assert Exception.message(error) =~ "no entity tag"
      assert Exception.message(error) =~ ":any"

      # Nothing was sent: a write with no precondition is not the write asked for.
      refute_receive {:request, _}, 100
    end
  end

  describe "a weak entity tag" do
    test "is refused here rather than sent off to fail forever" do
      store = store([ok("", [{"etag", ~s("x")}])])

      assert {:error, %Error{reason: :unsupported}} = Store.write(store, "bytes", ~s(W/"abc"))

      # Nothing was sent: a 412 from this would look like a conflict and is not.
      refute_receive {:request, _}, 100
    end

    test "and the error says why, and what to do about it" do
      store = store([])

      assert {:error, error} = Store.write(store, "bytes", ~s(W/"abc"))
      assert Exception.message(error) =~ "compares"
      assert Exception.message(error) =~ "compression"
      assert error.details.etag == ~s(W/"abc")
    end

    test "writing with :any goes through anyway, having been told" do
      store = store([ok("", [{"etag", ~s("new")}])])

      assert {:ok, _} = Store.write(store, "bytes", :any)
    end
  end

  describe "what it can promise" do
    test "a conditional write, which is the whole reason it exists" do
      assert Store.conditional_write?(Store.webdav("https://example.com/x.xlsx"))
    end

    test "and a workbook over it says so" do
      workbook = Workbook.xlsx(Store.webdav("https://example.com/x.xlsx"))

      assert Sheetshow.Backend.supports?(workbook, :conditional_write)
      assert Sheetshow.Backend.supports?(workbook, :atomic_batch)
      refute Sheetshow.Backend.supports?(workbook, :evaluates_formulas)
    end

    test "which is the difference between the two stores" do
      refute Sheetshow.Backend.supports?(Workbook.xlsx(Store.local("x.xlsx")), :conditional_write)

      assert Sheetshow.Backend.supports?(
               Workbook.xlsx(Store.webdav("https://e.com/x.xlsx")),
               :conditional_write
             )
    end
  end

  describe "exists?" do
    test "asks without reading the file" do
      store = store([ok("", [])])

      assert Store.exists?(store)
      assert_receive {:request, %{method: :HEAD}}
    end

    test "a file that is not there" do
      assert store([{404, "", "text/plain", []}]) |> Store.exists?() == false
    end
  end

  describe "a Nextcloud address" do
    test "is built the way the web interface spells it" do
      store = Store.nextcloud("https://cloud.example.com", "user", "budget/costs.xlsx")

      assert store.location ==
               "https://cloud.example.com/remote.php/dav/files/user/budget/costs.xlsx"
    end

    test "takes the username as the one to sign in with, unless told otherwise" do
      assert Store.nextcloud("https://c.example.com", "user", "x.xlsx").options[:username] ==
               "user"

      assert Store.nextcloud("https://c.example.com", "user", "x.xlsx", username: "someone").options[
               :username
             ] == "someone"
    end

    test "a trailing slash on the server, or a leading one on the path, changes nothing" do
      with_slashes = Store.nextcloud("https://c.example.com/", "user", "/x.xlsx")
      without = Store.nextcloud("https://c.example.com", "user", "x.xlsx")

      assert with_slashes.location == without.location
    end

    test "a path with a space in it is escaped, and its separators are not" do
      store = Store.nextcloud("https://c.example.com", "user", "my budget/costs 2026.xlsx")

      assert store.location =~ "/my%20budget/costs%202026.xlsx"
    end
  end

  # The point of the whole store: a workbook on a server somewhere, written
  # back only if nobody moved it underneath us.
  describe "a workbook over it" do
    defp workbook_bytes do
      {:ok, package} = Sheetshow.Xlsx.open(File.read!("test/fixtures/xlsxwriter.xlsx"))
      {:ok, bytes} = Sheetshow.Xlsx.encode(package)
      bytes
    end

    test "is read, planned against and written back with its entity tag" do
      bytes = workbook_bytes()

      url =
        TestServer.start([
          ok(bytes, [{"etag", ~s("v1")}]),
          ok("", [{"etag", ~s("v2")}])
        ])

      store = Store.webdav(url <> "/costs.xlsx", username: "user", password: "app-pw")
      workbook = Workbook.xlsx(store)

      row = Sheetshow.row(["Bus", 50], sheet: "Costs")
      assert {:ok, workbook} = Sheetshow.run([Sheetshow.Op.AppendRows.new(row)], workbook)
      assert Enum.sort(Map.keys(workbook.sheets)) == ["Costs", "log"]

      assert_receive {:request, %{method: :GET}}
      assert_receive {:request, %{method: :PUT} = put}

      # The version the read gave, sent back as the precondition, which is the
      # thing a local file cannot do.
      assert put.headers["if-match"] == ~s("v1")

      # And what was written is a workbook with the new row in it.
      {:ok, written} = Sheetshow.Xlsx.open(put.body)
      {:ok, sheet} = Sheetshow.Xlsx.sheet(written, "Costs")
      assert Enum.any?(sheet.cells, &(&1.value == "Bus"))
    end

    test "and a plan lost to somebody else is a conflict rather than a clobbering" do
      url =
        TestServer.start([
          ok(workbook_bytes(), [{"etag", ~s("v1")}]),
          {412, "", "text/plain", []}
        ])

      store = Store.webdav(url <> "/costs.xlsx", username: "user", password: "app-pw")
      row = Sheetshow.row(["Bus", 50], sheet: "Costs")

      assert {:error, %Error{reason: :conflict}} =
               Sheetshow.run([Sheetshow.Op.AppendRows.new(row)], Workbook.xlsx(store))
    end

    test "connecting reads it once and learns its sheets" do
      url = TestServer.start([ok(workbook_bytes(), [{"etag", ~s("v1")}])])
      store = Store.webdav(url <> "/costs.xlsx", username: "user", password: "app-pw")

      assert {:ok, workbook} = Sheetshow.connect(Workbook.xlsx(store))
      assert Enum.sort(Map.keys(workbook.sheets)) == ["Costs", "log"]
    end

    test "one that is not there is refused unless you said you meant it" do
      url = TestServer.start([{404, "", "text/plain", []}, {404, "", "text/plain", []}])
      store = Store.webdav(url <> "/costs.xlsx", username: "user", password: "app-pw")

      assert {:error, %Error{reason: :not_found}} = Sheetshow.connect(Workbook.xlsx(store))
      assert {:ok, _} = Sheetshow.connect(Workbook.xlsx(store, create: true))
    end
  end

  describe "options nobody reads" do
    test "are refused when the store is built, not when the file is fetched" do
      assert_raise ArgumentError, ~r/unknown keys \[:user\]/, fn ->
        Store.webdav("https://example.com/x.xlsx", user: "user", password: "pw")
      end

      assert_raise ArgumentError, ~r/unknown keys \[:timout\]/, fn ->
        Store.nextcloud("https://c.example.com", "user", "x.xlsx", http: [timout: 1])
      end
    end
  end

  describe "a store's secrets" do
    test "do not print, because a store is a value people pass around" do
      store = Store.webdav("https://example.com/x.xlsx", username: "user", password: "hunter2")
      printed = inspect(store)

      refute printed =~ "hunter2"
      assert printed =~ "https://example.com/x.xlsx"
    end
  end
end
