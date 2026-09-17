defmodule Sheetshow.HTTP do
  @moduledoc false
  # The one place Sheetshow talks to the network.
  #
  # OTP's :httpc, so the library has no dependencies and no pool of its own.
  # The shape here is deliberately small (a method, a URL, headers, a body),
  # so that swapping in another client later is a change to this file and
  # nothing else.
  #
  # TLS is verified explicitly rather than left to the OTP version's default:
  # before OTP 26 :httpc verified nothing at all.

  alias Sheetshow.Error

  @type response :: %{status: pos_integer(), headers: [{String.t(), String.t()}], body: binary()}

  @type method :: :get | :head | :post | :put | :delete

  @options [:timeout, :connect_timeout, :ssl]

  @doc "The options a client's `:http` list may hold, for the callers that check theirs."
  @spec options() :: [atom()]
  def options, do: @options

  @spec request(method(), String.t(), [{String.t(), String.t()}], binary() | nil, keyword()) ::
          {:ok, response()} | {:error, Error.t()}
  def request(method, url, headers, body \\ nil, opts \\ []) do
    {content_type, headers} = split_content_type(headers)
    charlist_url = String.to_charlist(url)
    charlist_headers = for {name, value} <- headers, do: {to_charlist(name), to_charlist(value)}

    request =
      case method do
        method when method in [:get, :head, :delete] ->
          {charlist_url, charlist_headers}

        method when method in [:post, :put] ->
          {charlist_url, charlist_headers, to_charlist(content_type), body || ""}
      end

    case :httpc.request(method, request, http_options(url, opts), body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok, %{status: status, headers: strings(response_headers), body: response_body}}

      {:error, reason} ->
        {:error,
         Error.new(
           :transport,
           "#{method |> Atom.to_string() |> String.upcase()} #{url} never got an answer: " <>
             "#{inspect(reason)}",
           url: url,
           reason: reason
         )}
    end
  end

  defp split_content_type(headers) do
    case Enum.split_with(headers, fn {name, _} -> String.downcase(name) == "content-type" end) do
      {[{_, content_type} | _], rest} -> {content_type, rest}
      {[], rest} -> {"application/octet-stream", rest}
    end
  end

  defp http_options(url, opts) do
    options = [
      timeout: Keyword.get(opts, :timeout, 30_000),
      connect_timeout: Keyword.get(opts, :connect_timeout, 10_000)
    ]

    if String.starts_with?(url, "https://") do
      [{:ssl, Keyword.get_lazy(opts, :ssl, &tls/0)} | options]
    else
      options
    end
  end

  defp tls do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp strings(headers) do
    for {name, value} <- headers, do: {List.to_string(name), List.to_string(value)}
  end
end
