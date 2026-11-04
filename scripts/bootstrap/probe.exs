defmodule NativeArtifact.BootstrapProbe do
  @url "https://repo.hex.pm/tarballs/http_fetch-0.21.19.tar"
  @sha256 "0a9947312418b21bc50a7ab192d3c8cd7c1f82b7483034133dd097b2f45e9119"
  @bytes 100_864
  @filename "http_fetch-0.21.19.tar"
  @family ~w(http_fetch http_core http_runtime ex_ssl elixir_quic elixir_quic_http3)a
  @native_tools ~w(cc c++ gcc g++ cpp clang clang++ rustc cargo rustup zig make cmake ninja as ld ar)

  def run([mode, directory]) when mode in ["online", "offline"] do
    for tool <- @native_tools do
      if System.find_executable(tool), do: raise("native tool is available: #{tool}")
    end

    {:ok, _apps} = Application.ensure_all_started(:crypto)
    path = Path.join(directory, @filename)

    case mode do
      "online" -> download(path)
      "offline" -> verify_file(path)
    end

    IO.puts(
      JSON.encode!(%{
        gate: "published_http_closure",
        mode: mode,
        elixir: System.version(),
        otp: List.to_string(:erlang.system_info(:otp_release)),
        bytes: @bytes,
        sha256: @sha256,
        native_tools_available: [],
        scope: "HTTP prerequisite and pinned local object; not package cache or NIF installation"
      })
    )
  end

  def run(_args), do: raise("usage: probe.exs online|offline DIRECTORY")

  defp download(path) do
    for app <- @family do
      case Application.load(app) do
        :ok -> :ok
        {:error, {:already_loaded, ^app}} -> :ok
      end

      ~c"0.21.19" = Application.spec(app, :vsn)
    end

    {:ok, _apps} = Application.ensure_all_started(:http_fetch)
    File.mkdir_p!(Path.dirname(path))
    part = path <> ".#{System.unique_integer([:positive])}.part"
    controller = HTTP.AbortController.new()
    deadline = System.monotonic_time(:millisecond) + 30_000

    promise =
      HTTP.fetch(@url,
        http_version: :http1,
        redirect: :manual,
        decode_body: false,
        stream_response: true,
        telemetry: false,
        tls_backend: :ssl,
        ssl: [
          verify: :verify_peer,
          cacertfile: ~c"/etc/ssl/certs/ca-certificates.crt",
          server_name_indication: ~c"repo.hex.pm",
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ],
        headers: [{"Accept-Encoding", "identity"}],
        response_header_limits: [
          max_head_bytes: 262_144,
          max_field_bytes: 65_536,
          max_fields: 256,
          max_connect_head_bytes: 65_536,
          max_informational_responses: 16,
          max_informational_bytes: 1_048_576
        ],
        connect_timeout: 10_000,
        read_idle_timeout: 5_000,
        response_stream_idle_timeout: 5_000,
        response_stream_ack_timeout: 5_000,
        timeout: 30_000,
        signal: controller
      )

    completion = HTTP.Promise.completion(promise)

    try do
      case HTTP.Promise.await(promise, remaining(deadline) + 1_000) do
        %{status: 200, headers: headers, body: stream} when is_pid(stream) ->
          if HTTP.Headers.get(headers, "content-encoding") not in [nil, "identity"],
            do: raise("unexpected Content-Encoding")

          case HTTP.Headers.get(headers, "content-length") do
            nil -> :ok
            "100864" -> :ok
            _other -> raise("unexpected Content-Length")
          end

          File.open!(part, [:write, :binary, :exclusive], fn file ->
            monitor = Process.monitor(stream)

            try do
              send(stream, {:read_chunk, self(), :ack})

              {bytes, hash} =
                receive_chunks(stream, monitor, file, deadline, 0, :crypto.hash_init(:sha256))

              verify_identity(bytes, :crypto.hash_final(hash))
              :ok = :file.sync(file)
            after
              Process.demonitor(monitor, [:flush])
            end
          end)

          :ok = HTTP.RequestCompletion.await(completion, 5_000)
          File.rename!(part, path)

        %{status: status} ->
          raise("unexpected HTTP response status: #{status}")

        {:error, reason} ->
          raise("HTTPS bootstrap request failed: #{inspect(reason)}")
      end
    after
      :ok = HTTP.AbortController.abort(controller)
      cleanup_result = HTTP.RequestCompletion.await(completion, 5_000)
      :ok = Agent.stop(controller)

      case File.rm(part) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> raise("partial-file cleanup failed: #{inspect(reason)}")
      end

      if cleanup_result != :ok, do: raise("request cleanup failed: #{inspect(cleanup_result)}")
    end

    verify_file(path)
  end

  defp receive_chunks(stream, monitor, file, deadline, bytes, hash) do
    receive do
      {:stream_chunk, ^stream, chunk, ack} when is_binary(chunk) ->
        if remaining(deadline) == 0, do: raise("bootstrap body deadline exceeded")
        bytes = bytes + byte_size(chunk)
        if bytes > @bytes, do: raise("archive exceeded pinned byte budget")
        hash = :crypto.hash_update(hash, chunk)
        :ok = IO.binwrite(file, chunk)
        send(stream, {:stream_chunk_ack, ack})
        receive_chunks(stream, monitor, file, deadline, bytes, hash)

      {:stream_end, ^stream} ->
        {bytes, hash}

      {:stream_trailers, ^stream, _headers} ->
        receive_chunks(stream, monitor, file, deadline, bytes, hash)

      {:stream_error, ^stream, _reason} ->
        raise("bootstrap response stream failed")

      {:DOWN, ^monitor, :process, ^stream, _reason} ->
        raise("bootstrap response stream terminated before completion")
    after
      min(remaining(deadline), 5_000) -> raise("bootstrap body deadline exceeded")
    end
  end

  defp verify_file(path) do
    %{size: @bytes, type: :regular} = File.lstat!(path)

    {bytes, hash} =
      path
      |> File.stream!([], 64 * 1024)
      |> Enum.reduce({0, :crypto.hash_init(:sha256)}, fn chunk, {bytes, hash} ->
        bytes = bytes + byte_size(chunk)
        if bytes > @bytes, do: raise("local object exceeded pinned byte budget")
        {bytes, :crypto.hash_update(hash, chunk)}
      end)

    verify_identity(bytes, :crypto.hash_final(hash))
  end

  defp verify_identity(@bytes, digest) do
    if Base.encode16(digest, case: :lower) != @sha256, do: raise("archive SHA-256 mismatch")
  end

  defp verify_identity(_bytes, _digest), do: raise("archive length mismatch")

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end

NativeArtifact.BootstrapProbe.run(System.argv())
