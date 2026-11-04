defmodule NativeArtifact.HTTPContractTest do
  use ExUnit.Case, async: true

  alias NativeArtifact.HTTPContractPeer, as: Peer

  @limits [
    max_head_bytes: 262_144,
    max_field_bytes: 65_536,
    max_fields: 256,
    max_connect_head_bytes: 65_536,
    max_informational_responses: 16,
    max_informational_bytes: 1_048_576
  ]
  @cert Path.expand("../fixtures/http_contract/localhost-cert.pem", __DIR__)
  @key Path.expand("../fixtures/http_contract/localhost-key.pem", __DIR__)
  @ca Path.expand("../fixtures/http_contract/ca-cert.pem", __DIR__)

  setup_all do
    {:ok, _started} = Application.ensure_all_started(:http_fetch)
    :ok
  end

  test "manual redirects accept heads above both historical 10KiB and 64KiB limits" do
    for count <- [3, 18] do
      head = response_head(302, padding(count), [{"Location", "https://example.invalid/asset"}])
      assert byte_size(head) > 10_240
      if count == 18, do: assert(byte_size(head) > 65_536)
      peer = Peer.respond(head)
      promise = fetch(peer.url)

      assert_empty_response(promise, 302)
      assert_clean(promise, peer)
    end
  end

  test "head byte limits include exactly the head and exclude a same-send raw body" do
    body = :binary.copy(<<0, 255, 31, 139>>, 16_384)
    head = response_head(200, [], [], byte_size(body))
    peer = Peer.respond([head, body])
    promise = fetch(peer.url, response_header_limits: limits(max_head_bytes: byte_size(head)))

    assert %HTTP.Response{status: 200, body: stream} = HTTP.Promise.await(promise, 3_000)
    assert {:ok, ^body} = read_body(stream)
    assert_clean(promise, peer)

    peer = Peer.respond([head, body])
    maximum = byte_size(head) - 1
    promise = fetch(peer.url, response_header_limits: limits(max_head_bytes: maximum))

    assert {:error,
            {:response_header_limit,
             %{stage: :response, limit: :max_head_bytes, maximum: ^maximum, observed: observed}}} =
             HTTP.Promise.await(promise, 3_000)

    assert observed == byte_size(head)
    assert_clean(promise, peer)
  end

  test "field byte and field count budgets admit exact boundaries and reject excess" do
    field = {"X-Limit", String.duplicate("x", 40)}
    head = response_head(200, [field])
    field_bytes = byte_size("X-Limit: " <> elem(field, 1))

    for {key, exact} <- [max_field_bytes: field_bytes, max_fields: 2] do
      peer = Peer.respond(head)
      promise = fetch(peer.url, response_header_limits: limits([{key, exact}]))
      assert_empty_response(promise, 200)
      assert_clean(promise, peer)

      peer = Peer.respond(head)
      maximum = exact - 1
      promise = fetch(peer.url, response_header_limits: limits([{key, maximum}]))

      assert {:error,
              {:response_header_limit,
               %{stage: :response, limit: ^key, maximum: ^maximum, observed: ^exact}}} =
               HTTP.Promise.await(promise, 3_000)

      assert_clean(promise, peer)
    end
  end

  test "fragmented large headers preserve the configured budget and body bytes" do
    body = "native-archive-bytes"
    head = response_head(200, padding(18), [], byte_size(body))
    assert byte_size(head) > 65_536

    peer =
      Peer.start(fn socket, _request ->
        for chunk <- chunks(head, 4_096) do
          :ok = :gen_tcp.send(socket, chunk)
          Process.sleep(2)
        end

        :gen_tcp.send(socket, body)
      end)

    promise = fetch(peer.url)
    assert %HTTP.Response{status: 200, body: stream} = HTTP.Promise.await(promise, 3_000)
    assert {:ok, ^body} = read_body(stream)
    assert_clean(promise, peer)
  end

  test "informational count and cumulative byte limits are finite and request-local" do
    informational = "HTTP/1.1 103 Early Hints\r\nLink: </fixture>\r\n\r\n"
    wire = [informational, informational, response_head(200)]

    for {key, exact} <- [
          max_informational_responses: 2,
          max_informational_bytes: 2 * byte_size(informational)
        ] do
      peer = Peer.respond(wire)
      promise = fetch(peer.url, response_header_limits: limits([{key, exact}]))
      assert_empty_response(promise, 200)
      assert_clean(promise, peer)

      peer = Peer.respond(wire)
      maximum = exact - 1
      promise = fetch(peer.url, response_header_limits: limits([{key, maximum}]))

      assert {:error,
              {:response_header_limit,
               %{stage: :response, limit: ^key, maximum: ^maximum, observed: ^exact}}} =
               HTTP.Promise.await(promise, 3_000)

      assert_clean(promise, peer)
    end
  end

  test "CONNECT heads larger than 16KiB reach verified origin TLS and streamed bytes" do
    head = "HTTP/1.1 200 Connection Established\r\n" <> header_lines(padding(6)) <> "\r\n"
    assert byte_size(head) > 16_384

    peer =
      Peer.start(fn socket, request ->
        assert String.starts_with?(request, "CONNECT localhost:443 HTTP/1.1\r\n")
        :ok = :gen_tcp.send(socket, head)

        {:ok, tls} =
          :ssl.handshake(
            socket,
            [
              certfile: String.to_charlist(@cert),
              keyfile: String.to_charlist(@key),
              active: false
            ],
            2_000
          )

        try do
          {:ok, origin_request} = Peer.receive_head(tls, :ssl)
          assert String.starts_with?(origin_request, "GET /artifact HTTP/1.1\r\n")
          :ssl.send(tls, [response_head(200, [], [], 8), "verified"])
        after
          :ssl.close(tls)
        end
      end)

    promise =
      fetch("https://localhost/artifact",
        proxy: {:http, "127.0.0.1", peer.port, [timeout: 2_000]},
        ssl: [verify: :verify_peer, cacertfile: String.to_charlist(@ca)]
      )

    assert %HTTP.Response{status: 200, body: stream} = HTTP.Promise.await(promise, 3_000)
    assert {:ok, "verified"} = read_body(stream)
    assert_clean(promise, peer)
  end

  test "CONNECT head budget excess is a structured connect-stage failure" do
    head = "HTTP/1.1 200 Connection Established\r\n" <> header_lines(padding(6)) <> "\r\n"

    peer =
      Peer.start(fn socket, _request ->
        :ok = :gen_tcp.send(socket, head)
        Peer.wait_closed(socket)
      end)

    maximum = byte_size(head) - 1

    promise =
      fetch("https://localhost/artifact",
        proxy: {:http, "127.0.0.1", peer.port, [timeout: 2_000]},
        response_header_limits: limits(max_connect_head_bytes: maximum)
      )

    assert {:error,
            {:response_header_limit,
             %{
               stage: :connect,
               limit: :max_connect_head_bytes,
               maximum: ^maximum,
               observed: observed
             }}} = HTTP.Promise.await(promise, 3_000)

    assert observed == byte_size(head)
    assert_clean(promise, peer)
  end

  @tag capture_log: true
  test "an origin chain from an untrusted CA is rejected before an origin request" do
    peer = tls_rejection_peer("localhost", :unknown_ca)

    promise =
      fetch("https://localhost/artifact",
        proxy: {:http, "127.0.0.1", peer.port, [timeout: 2_000]},
        ssl: [verify: :verify_peer, cacerts: []]
      )

    assert {:error, {:tls_alert, {:unknown_ca, _details}}} = HTTP.Promise.await(promise, 3_000)
    assert_rejected_tls_completion(promise, peer)
  end

  @tag capture_log: true
  test "a trusted origin chain with the wrong hostname is rejected before an origin request" do
    peer = tls_rejection_peer("wrong-origin.invalid", :handshake_failure)

    promise =
      fetch("https://wrong-origin.invalid/artifact",
        proxy: {:http, "127.0.0.1", peer.port, [timeout: 2_000]},
        ssl: [verify: :verify_peer, cacertfile: String.to_charlist(@ca)]
      )

    assert {:error, {:tls_alert, {:handshake_failure, details}}} =
             HTTP.Promise.await(promise, 3_000)

    assert to_string(details) =~ "hostname_check_failed"
    assert_rejected_tls_completion(promise, peer)
  end

  test "concurrent requests do not share header budgets" do
    head = response_head(200, padding(18))
    small = Peer.respond(head)
    large = Peer.respond(head)
    small_promise = fetch(small.url, response_header_limits: limits(max_head_bytes: 65_536))
    large_promise = fetch(large.url)

    assert_empty_response(large_promise, 200)

    assert {:error, {:response_header_limit, %{limit: :max_head_bytes, maximum: 65_536}}} =
             HTTP.Promise.await(small_promise, 3_000)

    assert_clean(large_promise, large)
    assert_clean(small_promise, small)
  end

  test "cancellation before response headers closes the request and its resources" do
    peer = Peer.start(fn socket, _request -> Peer.wait_closed(socket) end)
    controller = HTTP.AbortController.new()
    on_exit(fn -> if Process.alive?(controller), do: Agent.stop(controller) end)
    promise = fetch(peer.url, signal: controller)
    assert {:ok, "GET /artifact HTTP/1.1\r\n" <> _headers} = Peer.request(peer)
    assert :ok = HTTP.AbortController.abort(controller)
    assert {:error, :aborted} = HTTP.Promise.await(promise, 3_000)
    assert_clean(promise, peer)
  end

  test "read-idle and total deadlines terminate stalled header reads distinctly" do
    for {options, expected} <- [
          {[read_idle_timeout: 100, timeout: 2_000], :read_idle_timeout},
          {[read_idle_timeout: 2_000, timeout: 100], :request_timeout}
        ] do
      peer = Peer.start(fn socket, _request -> Peer.wait_closed(socket) end)
      promise = fetch(peer.url, options)
      assert {:error, ^expected} = HTTP.Promise.await(promise, 3_000)
      assert_clean(promise, peer)
    end
  end

  test "total deadline remains active after headers resolve into an acknowledged stream" do
    peer =
      Peer.start(fn socket, _request ->
        :ok = :gen_tcp.send(socket, response_head(200, [], [], 4))
        Peer.wait_closed(socket)
      end)

    promise = fetch(peer.url, timeout: 200, read_idle_timeout: 2_000)
    assert %HTTP.Response{status: 200, body: stream} = HTTP.Promise.await(promise, 3_000)
    assert {:error, :request_timeout} = read_body(stream)
    assert_clean(promise, peer)
  end

  defp fetch(url, overrides \\ []) do
    options = [
      http_version: :http1,
      redirect: :manual,
      decode_body: false,
      stream_response: true,
      tls_backend: :ssl,
      connect_timeout: 2_000,
      read_idle_timeout: 2_000,
      timeout: 2_500,
      headers: [{"Accept-Encoding", "identity"}],
      response_header_limits: @limits
    ]

    promise = HTTP.fetch(url, Keyword.merge(options, overrides))
    completion = HTTP.Promise.completion(promise)
    on_exit(fn -> HTTP.RequestCompletion.abort_and_await(completion, 1_000) end)
    promise
  end

  defp limits(overrides), do: Keyword.merge(@limits, overrides)

  defp assert_clean(promise, peer) do
    assert :ok = HTTP.RequestCompletion.await(HTTP.Promise.completion(promise), 3_000)
    assert :ok = Peer.await(peer)
  end

  defp assert_empty_response(promise, status) do
    assert %HTTP.Response{status: ^status, body: body} = HTTP.Promise.await(promise, 3_000)
    assert {:ok, ""} = read_body(body)
  end

  defp tls_rejection_peer(host, expected_alert) do
    Peer.start(fn socket, request ->
      assert String.starts_with?(request, "CONNECT #{host}:443 HTTP/1.1\r\n")
      :ok = :gen_tcp.send(socket, "HTTP/1.1 200 Connection Established\r\n\r\n")

      # An established TLS session would permit an origin GET and must fail this
      # peer assertion. Only the expected client rejection alert is accepted.
      assert {:error, {:tls_alert, {^expected_alert, _details}}} =
               :ssl.handshake(
                 socket,
                 [
                   certfile: String.to_charlist(@cert),
                   keyfile: String.to_charlist(@key),
                   active: false
                 ],
                 2_000
               )

      :ok
    end)
  end

  defp assert_rejected_tls_completion(promise, peer) do
    # Failed OTP TLS upgrade exposes no receiver/sender handle. The published
    # completion API reports this unavailable proof instead of claiming cleanup.
    assert {:error, :cleanup_unconfirmed} =
             HTTP.RequestCompletion.await(HTTP.Promise.completion(promise), 3_000)

    assert :ok = Peer.await(peer)
  end

  defp response_head(status, fields \\ [], extra \\ [], size \\ 0) do
    "HTTP/1.1 #{status} Fixture\r\n" <>
      header_lines(fields ++ extra ++ [{"Content-Length", Integer.to_string(size)}]) <> "\r\n"
  end

  defp header_lines(fields), do: Enum.map_join(fields, "", fn {k, v} -> "#{k}: #{v}\r\n" end)

  defp padding(count),
    do: for(i <- 1..count, do: {"X-Padding-#{i}", String.duplicate("x", 4_096)})

  defp chunks("", _size), do: []
  defp chunks(bytes, size) when byte_size(bytes) <= size, do: [bytes]

  defp chunks(<<chunk::binary-size(4_096), rest::binary>>, 4_096),
    do: [chunk | chunks(rest, 4_096)]

  defp read_body(body) when is_binary(body), do: {:ok, body}
  defp read_body(stream), do: read_body(stream, [], System.monotonic_time(:millisecond) + 3_000)

  defp read_body(stream, chunks, deadline) do
    send(stream, {:read_chunk, self(), :ack})

    receive do
      {:stream_chunk, ^stream, bytes, ack} ->
        send(stream, {:stream_chunk_ack, ack})
        read_body(stream, [bytes | chunks], deadline)

      {:stream_end, ^stream} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:stream_error, ^stream, reason} ->
        {:error, reason}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :test_stream_timeout}
    end
  end
end
