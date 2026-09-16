defmodule Sheetshow.Store.WebDAV do
  @moduledoc """
  A spreadsheet file on a WebDAV server: Nextcloud, ownCloud, or anything else
  that speaks it.

  This is the store that can do what a local file cannot: refuse a write that
  would clobber somebody. A read brings back the file's `ETag`, a write sends it
  back as `If-Match`, and the server compares the two before it writes anything.
  A file that changed in between gets `412 Precondition Failed`, which arrives
  here as `%Sheetshow.Error{reason: :conflict}`, and because nothing was
  written, the work can be re-read, re-planned and tried again.

      store = Sheetshow.Store.nextcloud("https://cloud.example.com", "user", "budget/costs.xlsx",
                username: "user", password: System.fetch_env!("NEXTCLOUD_APP_PASSWORD"))

      {:ok, workbook} = Sheetshow.Workbook.xlsx(store) |> Sheetshow.connect()

  ## App passwords

  Nextcloud takes an ordinary Basic auth header, but an account with two-factor
  authentication or an external identity provider will not accept the login
  password over WebDAV. It wants an **app password**, made under Personal
  settings → Security → Devices & sessions. That is the usual reason a set of
  credentials that works in a browser gets a 401 here.

  ## Weak entity tags, and the 412 that never goes away

  `If-Match` uses *strong* comparison: RFC 7232 says both tags must be non-weak
  and match exactly, so an entity tag marked weak (`W/"…"`) can never satisfy
  it. Servers hand one back legitimately whenever the response body was
  compressed (nginx with `gzip on`, Cloudflare, Traefik, PHP's
  `zlib.output_compression`), and a client that sends it back anyway gets 412
  forever, no matter how many times it re-reads.

  Two things here about that. Reads ask for `Accept-Encoding: identity`, so the
  server has no reason to compress and every reason to give a strong tag. And a
  write holding a weak one is refused *here*, with an error that says what to
  do, rather than sent off to fail in a way that looks like a conflict and is
  not one.
  """

  @behaviour Sheetshow.Store

  alias Sheetshow.{Error, HTTP, Store}

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  @impl true
  def read(%Store{location: url} = store) do
    # identity, so the body is not compressed and the entity tag comes back
    # strong enough to send back as a precondition.
    headers = [{"accept-encoding", "identity"} | auth(store)]

    with {:ok, response} <- HTTP.request(:get, url, headers, nil, http(store)) do
      case response.status do
        status when status in 200..299 -> {:ok, {response.body, etag(response) || :unknown}}
        404 -> {:error, not_found(store)}
        410 -> {:error, not_found(store)}
        status -> {:error, http(store, status, response, "GET")}
      end
    end
  end

  @impl true
  def write(%Store{location: url} = store, bytes, precondition) do
    with {:ok, condition} <- condition(store, precondition) do
      headers = [{"content-type", @xlsx}] ++ condition ++ auth(store)

      with {:ok, response} <- HTTP.request(:put, url, headers, bytes, http(store)) do
        case response.status do
          status when status in 200..299 -> version(store, response)
          412 -> {:error, Store.conflict(store, conflicted(store, precondition))}
          # Some servers answer a failed If-None-Match with 409 rather than 412.
          409 -> {:error, Store.conflict(store, conflicted(store, precondition))}
          status -> {:error, http(store, status, response, "PUT")}
        end
      end
    end
  end

  @impl true
  def exists?(%Store{location: url} = store) do
    case HTTP.request(:head, url, auth(store), nil, http(store)) do
      {:ok, %{status: status}} -> status in 200..299
      {:error, _} -> false
    end
  end

  # The whole reason this store exists.
  @impl true
  def conditional_write?(%Store{}), do: true

  # --- preconditions ---

  # `:any` writes over whatever is there. `:absent` is the version of a file
  # that is not there, so it becomes "only if it still is not", which is what
  # stops two processes both believing they created it.
  defp condition(_store, :any), do: {:ok, []}
  defp condition(_store, :absent), do: {:ok, [{"if-none-match", "*"}]}

  # A server that sent no entity tag left us nothing to compare against. Saying
  # so is better than sending nothing and calling the write conditional.
  defp condition(store, :unknown) do
    {:error,
     Error.new(
       :unsupported,
       "#{store.location} came back with no entity tag, so there is nothing to make a " <>
         "conditional write out of. Read it again, or write with :any and take the risk.",
       location: store.location
     )}
  end

  defp condition(store, "W/" <> _ = weak) do
    {:error,
     Error.new(
       :unsupported,
       "#{store.location} came back with the weak entity tag #{weak}, and If-Match compares " <>
         "strongly, so sending it back would be refused however often it was tried. A server " <>
         "answers weakly when it has compressed the body; turning compression off for this " <>
         "path is the fix. Writing with :any writes anyway, and takes the risk.",
       location: store.location,
       etag: weak
     )}
  end

  defp condition(_store, etag) when is_binary(etag), do: {:ok, [{"if-match", etag}]}

  defp conditioned(:any), do: "was written over whatever was there"
  defp conditioned(:absent), do: "was to be created"
  defp conditioned(_etag), do: "was read"

  defp conflicted(store, precondition) do
    "#{store.location} has changed since it #{conditioned(precondition)}"
  end

  # --- what came back ---

  # The standard header is the one `If-Match` compares against. Nextcloud sends
  # `OC-ETag` as well, and they are not always written the same way, so it is
  # only worth having when there is no `ETag` at all.
  defp etag(response) do
    header(response, "etag") || header(response, "oc-etag")
  end

  defp header(%{headers: headers}, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  # A write answers with the new entity tag, usually. When it does not, one
  # HEAD is what it costs to know what to send next time rather than guess, and
  # a server that will not say either leaves the state `:unknown`.
  defp version(store, response) do
    case etag(response) do
      nil -> {:ok, head_etag(store)}
      etag -> {:ok, etag}
    end
  end

  defp head_etag(%Store{location: url} = store) do
    case HTTP.request(:head, url, auth(store), nil, http(store)) do
      {:ok, %{status: status} = response} when status in 200..299 -> etag(response) || :unknown
      _ -> :unknown
    end
  end

  # --- the request ---

  defp auth(%Store{options: options}) do
    case {Keyword.get(options, :username), Keyword.get(options, :password)} do
      {username, password} when is_binary(username) and is_binary(password) ->
        [{"authorization", "Basic " <> Base.encode64("#{username}:#{password}")}]

      _ ->
        Keyword.get(options, :headers, [])
    end
  end

  defp http(%Store{options: options}), do: Keyword.get(options, :http, [])

  defp not_found(store) do
    Error.new(:not_found, "there is nothing at #{store.location}", location: store.location)
  end

  defp http(store, status, response, method) do
    Error.new(
      :http,
      "#{method} #{store.location} answered #{status}" <> explain(status),
      status: status,
      location: store.location,
      body: String.slice(response.body, 0, 500)
    )
  end

  defp explain(401),
    do:
      ": the credentials were refused. Nextcloud wants an app password rather than the " <>
        "account's own when the account has two-factor authentication or signs in elsewhere."

  defp explain(403), do: ": the credentials are known but not allowed to write here"
  defp explain(423), do: ": the file is locked by somebody else"
  defp explain(507), do: ": the server is out of room"
  defp explain(_status), do: ""
end
