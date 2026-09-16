defmodule Sheetshow.TestServer do
  @moduledoc false
  # An HTTP server on localhost that answers with what you tell it to, so the
  # HTTP path is exercised for real without a network.
  #
  # Each request it takes is sent to the test process as `{:request, request}`,
  # so `assert_receive` is how you look at what Sheetshow sent.

  @type header :: {String.t(), String.t()}
  @type response ::
          {pos_integer(), binary()}
          | {pos_integer(), binary(), String.t()}
          | {pos_integer(), binary(), String.t(), [header()]}

  @type handler :: (request :: map(), state :: term() -> {response(), state :: term()})

  @doc """
  Starts a server that answers the given responses in order, and returns its
  base URL. Given `{handler, state}` instead, each request is answered by the
  handler, which is how a server that has to remember something, such as a
  file and its entity tag, is written.
  """
  @spec start([response()] | {handler(), term()}) :: String.t()
  def start(responses) when is_list(responses) or is_tuple(responses) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :http_bin,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    test = self()
    spawn(fn -> serve(listen, responses, test) end)

    "http://127.0.0.1:#{port}"
  end

  defp serve(listen, responses, test) do
    with {:ok, socket} <- :gen_tcp.accept(listen) do
      request =
        case request(socket) do
          {:ok, request} ->
            send(test, {:request, request})
            request

          :error ->
            nil
        end

      {response, rest} = answer(responses, request)
      reply(socket, response)
      :gen_tcp.close(socket)
      serve(listen, rest, test)
    end
  end

  defp answer([response | rest], _request), do: {response, rest}
  defp answer([], _request), do: {{500, ~s({"error":"the test server ran out of answers"})}, []}
  defp answer({handler, state}, nil), do: {{400, "unreadable request"}, {handler, state}}

  defp answer({handler, state}, request) do
    {response, state} = handler.(request, state)
    {response, {handler, state}}
  end

  defp request(socket) do
    with {:ok, {:http_request, method, {:abs_path, path}, _version}} <- :gen_tcp.recv(socket, 0),
         {:ok, headers} <- headers(socket, []) do
      {:ok,
       %{
         method: method,
         path: path |> String.split("?") |> hd(),
         query: path |> URI.parse() |> Map.get(:query) |> decode_query(),
         params: path |> URI.parse() |> Map.get(:query) |> pairs(),
         headers: headers,
         body: body(socket, headers)
       }}
    else
      _ -> :error
    end
  end

  defp headers(socket, acc) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_header, _, name, _, value}} ->
        headers(socket, [{name |> to_string() |> String.downcase(), to_string(value)} | acc])

      {:ok, :http_eoh} ->
        {:ok, Map.new(acc)}

      other ->
        other
    end
  end

  defp body(socket, headers) do
    case Integer.parse(Map.get(headers, "content-length", "0")) do
      {length, _} when length > 0 ->
        :inet.setopts(socket, packet: :raw)
        {:ok, body} = :gen_tcp.recv(socket, length)
        body

      _ ->
        ""
    end
  end

  defp decode_query(nil), do: %{}
  defp decode_query(query), do: URI.decode_query(query)

  # The same parameter can be given more than once (`ranges` on a batch read),
  # and a map would keep only the last of them.
  defp pairs(nil), do: []
  defp pairs(query), do: query |> URI.query_decoder() |> Enum.to_list()

  defp reply(socket, {status, body}), do: reply(socket, {status, body, "application/json", []})

  defp reply(socket, {status, body, content_type}) do
    reply(socket, {status, body, content_type, []})
  end

  defp reply(socket, {status, body, content_type, headers}) do
    :inet.setopts(socket, packet: :raw)

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} OK\r\n",
      "content-type: #{content_type}\r\n",
      for({name, value} <- headers, do: "#{name}: #{value}\r\n"),
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ])
  end
end
