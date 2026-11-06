defmodule NativeArtifact.Manifest.JSON do
  @moduledoc false

  alias NativeArtifact.Error

  def decode(binary, limits) when is_binary(binary) do
    with :ok <- input_bytes(binary, limits),
         true <- String.valid?(binary),
         :ok <- scan(binary, 0, false, false, false, 0, limits) do
      decode_object_keys(binary)
    else
      false -> failure(:invalid_json)
      error -> error
    end
  end

  def decode(_other, _limits), do: failure(:expected_json_binary)

  def validate(value, limits) do
    case walk(value, 0, {0, 0}, limits) do
      {:ok, _usage} -> :ok
      error -> error
    end
  end

  defp input_bytes(binary, limits) do
    if byte_size(binary) <= limits.max_manifest_bytes,
      do: :ok,
      else: limit(:max_manifest_bytes, limits)
  end

  # Bound nesting and token allocation before calling the OTP JSON decoder. The
  # decoder remains responsible for JSON grammar, escapes, numbers and UTF-8.
  # Object keys count as nodes in both this scan and the decoded-value walk.
  defp scan(_binary, depth, _string, _escape, _scalar, _nodes, limits)
       when depth > limits.max_depth,
       do: limit(:max_depth, limits)

  defp scan(_binary, _depth, _string, _escape, _scalar, nodes, limits)
       when nodes > limits.max_nodes,
       do: limit(:max_nodes, limits)

  defp scan(<<>>, 0, false, false, _scalar, _nodes, _limits), do: :ok

  defp scan(<<>>, _depth, _string, _escape, _scalar, _nodes, _limits),
    do: failure(:invalid_json)

  defp scan(<<_byte, rest::binary>>, depth, true, true, scalar, nodes, limits),
    do: scan(rest, depth, true, false, scalar, nodes, limits)

  defp scan(<<92, rest::binary>>, depth, true, false, scalar, nodes, limits),
    do: scan(rest, depth, true, true, scalar, nodes, limits)

  defp scan(<<34, rest::binary>>, depth, true, false, _scalar, nodes, limits),
    do: scan(rest, depth, false, false, false, nodes, limits)

  defp scan(<<_byte, rest::binary>>, depth, true, false, scalar, nodes, limits),
    do: scan(rest, depth, true, false, scalar, nodes, limits)

  defp scan(<<34, rest::binary>>, depth, false, false, _scalar, nodes, limits),
    do: scan(rest, depth, true, false, false, nodes + 1, limits)

  defp scan(<<byte, rest::binary>>, depth, false, false, _scalar, nodes, limits)
       when byte in [123, 91],
       do: scan(rest, depth + 1, false, false, false, nodes + 1, limits)

  defp scan(<<byte, rest::binary>>, depth, false, false, _scalar, nodes, limits)
       when byte in [125, 93] and depth > 0,
       do: scan(rest, depth - 1, false, false, false, nodes, limits)

  defp scan(<<byte, rest::binary>>, depth, false, false, _scalar, nodes, limits)
       when byte in [32, 9, 10, 13, 44, 58],
       do: scan(rest, depth, false, false, false, nodes, limits)

  defp scan(<<_byte, rest::binary>>, depth, false, false, scalar, nodes, limits),
    do: scan(rest, depth, false, false, true, nodes + if(scalar, do: 0, else: 1), limits)

  defp decode_object_keys(binary) do
    decoders = [
      object_start: fn _acc -> %{} end,
      object_push: fn key, value, object ->
        if Map.has_key?(object, key), do: throw(:native_artifact_duplicate_json_key)
        Map.put(object, key, value)
      end,
      object_finish: fn object, old_acc -> {object, old_acc} end
    ]

    case Elixir.JSON.decode(binary, nil, decoders) do
      {value, nil, rest} ->
        if Regex.match?(~r/\A[ \t\r\n]*\z/, rest),
          do: {:ok, value},
          else: failure(:invalid_json)

      {:error, _reason} ->
        failure(:invalid_json)
    end
  rescue
    _error in [ArgumentError, SystemLimitError] -> failure(:invalid_json)
  catch
    :native_artifact_duplicate_json_key -> failure(:duplicate_json_key)
  end

  defp walk(value, depth, usage, limits) when is_map(value) do
    if depth + 1 > limits.max_depth do
      limit(:max_depth, limits)
    else
      with {:ok, usage} <- bump(usage, 2 + max(0, 2 * map_size(value) - 1), 1, limits) do
        if map_size(value) * 2 > limits.max_nodes - elem(usage, 1) do
          limit(:max_nodes, limits)
        else
          Enum.reduce_while(Map.to_list(value), {:ok, usage}, fn {key, item}, {:ok, usage} ->
            result =
              if is_binary(key) do
                with {:ok, usage} <- walk(key, depth + 1, usage, limits),
                     do: walk(item, depth + 1, usage, limits)
              else
                failure(:non_json_value)
              end

            continue(result)
          end)
        end
      end
    end
  end

  defp walk(value, depth, usage, limits) when is_list(value) do
    if depth + 1 > limits.max_depth do
      limit(:max_depth, limits)
    else
      with {:ok, usage} <- bump(usage, 2, 1, limits),
           do: walk_list(value, depth + 1, usage, limits, true)
    end
  end

  defp walk(value, _depth, usage, limits) when is_binary(value) do
    cond do
      byte_size(value) > limits.max_manifest_bytes -> limit(:max_manifest_bytes, limits)
      not String.valid?(value) -> failure(:non_json_value)
      true -> bump(usage, string_bytes(value, 2), 1, limits)
    end
  end

  defp walk(value, _depth, usage, limits) when value in [true, false, nil] do
    bump(usage, if(value == false, do: 5, else: 4), 1, limits)
  end

  defp walk(value, _depth, usage, limits) when is_integer(value) do
    if :erlang.external_size(value) > limits.max_manifest_bytes + 16,
      do: limit(:max_manifest_bytes, limits),
      else: bump(usage, byte_size(Integer.to_string(value)), 1, limits)
  end

  defp walk(value, _depth, usage, limits) when is_float(value),
    do: bump(usage, byte_size(Elixir.JSON.encode!(value)), 1, limits)

  defp walk(_other, _depth, _usage, _limits), do: failure(:non_json_value)

  defp walk_list([], _depth, usage, _limits, _first), do: {:ok, usage}

  defp walk_list([item | rest], depth, usage, limits, first) do
    with {:ok, usage} <- bump(usage, if(first, do: 0, else: 1), 0, limits),
         {:ok, usage} <- walk(item, depth, usage, limits) do
      walk_list(rest, depth, usage, limits, false)
    end
  end

  defp walk_list(_improper, _depth, _usage, _limits, _first), do: failure(:non_json_value)

  defp string_bytes(<<>>, bytes), do: bytes

  defp string_bytes(<<byte, rest::binary>>, bytes) do
    added =
      cond do
        byte in [34, 92, 8, 9, 10, 12, 13] -> 2
        byte < 32 -> 6
        true -> 1
      end

    string_bytes(rest, bytes + added)
  end

  defp bump({bytes, nodes}, add_bytes, add_nodes, limits) do
    cond do
      bytes + add_bytes > limits.max_manifest_bytes -> limit(:max_manifest_bytes, limits)
      nodes + add_nodes > limits.max_nodes -> limit(:max_nodes, limits)
      true -> {:ok, {bytes + add_bytes, nodes + add_nodes}}
    end
  end

  defp continue({:ok, _usage} = result), do: {:cont, result}
  defp continue(error), do: {:halt, error}

  defp limit(name, limits),
    do: failure(:limit_exceeded, %{limit: name, maximum: Map.fetch!(limits, name)})

  defp failure(reason, details \\ %{}),
    do: {:error, Error.new(:invalid_manifest, Map.merge(%{path: [], reason: reason}, details))}
end
