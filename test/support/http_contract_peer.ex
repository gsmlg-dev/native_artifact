defmodule NativeArtifact.HTTPContractPeer do
  @moduledoc false

  # A one-request loopback peer. All reads/accepts and shutdown waits are bounded;
  # each test owns its listener and peer process independently.
  def start(handler) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    owner = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, socket} = :gen_tcp.accept(listener, 3_000)

            try do
              {:ok, request} = receive_head(socket)
              send(owner, {:http_contract_request, token, request})
              handler.(socket, request)
            after
              :gen_tcp.close(socket)
            end
          rescue
            error -> {:error, {error, __STACKTRACE__}}
          catch
            kind, reason -> {:error, {kind, reason}}
          after
            :gen_tcp.close(listener)
          end

        send(owner, {:http_contract_result, token, result})
      end)

    peer = %{
      pid: pid,
      monitor: monitor,
      token: token,
      listener: listener,
      port: port,
      url: "http://127.0.0.1:#{port}/artifact"
    }

    ExUnit.Callbacks.on_exit(fn -> stop(peer) end)
    peer
  end

  def respond(bytes), do: start(fn socket, _request -> :gen_tcp.send(socket, bytes) end)

  def request(peer) do
    receive do
      {:http_contract_request, token, request} when token == peer.token -> {:ok, request}
    after
      3_000 -> {:error, :peer_request_timeout}
    end
  end

  def await(peer) do
    receive do
      {:http_contract_result, token, result} when token == peer.token ->
        Process.demonitor(peer.monitor, [:flush])
        result
    after
      4_000 -> {:error, :peer_completion_timeout}
    end
  end

  def wait_closed(socket) do
    case :gen_tcp.recv(socket, 0, 3_000) do
      {:error, :closed} -> :ok
      other -> {:error, {:expected_closed_socket, other}}
    end
  end

  def receive_head(socket, transport \\ :gen_tcp, bytes \\ "") do
    if String.contains?(bytes, "\r\n\r\n") do
      {:ok, bytes}
    else
      case transport.recv(socket, 0, 3_000) do
        {:ok, chunk} when byte_size(bytes) + byte_size(chunk) <= 65_536 ->
          receive_head(socket, transport, bytes <> chunk)

        {:ok, _chunk} ->
          {:error, :test_request_too_large}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp stop(peer) do
    :gen_tcp.close(peer.listener)
    monitor = Process.monitor(peer.pid)
    if Process.alive?(peer.pid), do: Process.exit(peer.pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    after
      1_000 -> raise "HTTP contract peer did not stop"
    end
  end
end
