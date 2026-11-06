defmodule NativeArtifact.Resolver.Input do
  @moduledoc false
  alias NativeArtifact.{Error, Manifest, Target}

  @max_bytes 4 * 1024 * 1024
  @evidence_keys ~w(target nif erts os_version libc_version vm_variant system_libraries binding)a
  @target_fields ~w(os arch libc object_format cpu_baseline pointer_width endianness source)a
  @module ~r/\A(?:Elixir\.[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*|[a-z][A-Za-z0-9_@]*)\z/
  @version ~r/\A[0-9]+(?:\.[0-9]+){1,3}\z/
  @wire %{
    os: %{linux: "linux", macos: "macos"},
    arch: %{x86_64: "x86_64", aarch64: "aarch64"},
    libc: %{glibc: "glibc", musl: "musl", none: "none"}
  }

  def options(opts, allowed) do
    if :erlang.external_size(opts) <= @max_bytes,
      do: options_list(opts, allowed, %{}),
      else: invalid(:options, :limit_exceeded)
  end

  defp options_list([], _allowed, values), do: {:ok, values}

  defp options_list([{key, value} | rest], allowed, values) do
    cond do
      key not in allowed -> invalid(:options, :unknown_option)
      Map.has_key?(values, key) -> invalid(:options, :duplicate_option)
      true -> options_list(rest, allowed, Map.put(values, key, value))
    end
  end

  defp options_list(_other, _allowed, _values), do: invalid(:options, :expected_keyword)

  def manifest(%Manifest{} = manifest, limits),
    do: Manifest.validate(Map.get(manifest, :data), limits)

  def manifest(json, limits) when is_binary(json), do: Manifest.decode(json, limits)
  def manifest(data, limits), do: Manifest.validate(data, limits)

  def selector(nil), do: {:ok, nil}

  def selector(id) do
    if string?(id, 1024) and Regex.match?(~r/\A[a-z][a-z0-9_.-]*\z/, id),
      do: {:ok, id},
      else: invalid(:artifact_id, :invalid_selector)
  end

  def evidence(value) when is_map(value) do
    cond do
      :erlang.external_size(value) > @max_bytes -> invalid(:evidence, :limit_exceeded)
      Map.keys(value) -- @evidence_keys != [] -> invalid(:evidence, :unknown_field)
      true -> normalize_evidence(value)
    end
  end

  def evidence(nil), do: missing(:target)
  def evidence(_other), do: invalid(:evidence, :expected_map)

  defp normalize_evidence(value) do
    with {:ok, target} <- target(Map.get(value, :target)),
         {:ok, nif} <- nif(Map.get(value, :nif)),
         :ok <- version(Map.get(value, :erts), :erts),
         :ok <- version(Map.get(value, :os_version), :os_version),
         :ok <- version(Map.get(value, :libc_version), :libc_version),
         :ok <- optional_string(Map.get(value, :vm_variant), :vm_variant, 64),
         :ok <- libraries(Map.get(value, :system_libraries)),
         :ok <- binding_evidence(Map.get(value, :binding)) do
      {:ok,
       Map.merge(Map.new(@evidence_keys, &{&1, nil}), value)
       |> Map.put(:target, target)
       |> Map.put(:nif, nif)
       |> Map.put(:system_libraries, normalize_libraries(Map.get(value, :system_libraries)))}
    end
  end

  defp target(nil), do: missing(:target)

  defp target(%Target{} = value) do
    with true <- Map.keys(value) -- [:__struct__ | @target_fields] == [],
         {:ok, os} <- wire(value, :os),
         {:ok, arch} <- wire(value, :arch),
         {:ok, libc} <- wire(value, :libc),
         {:ok, canonical} <- Target.new(%{"os" => os, "arch" => arch, "libc" => libc}) do
      if Enum.all?(@target_fields, &(Map.get(value, &1) == Map.get(canonical, &1))),
        do: {:ok, canonical},
        else:
          {:error,
           Error.new(:unsupported_target, %{field: :target, reason: :unsupported_invariant})}
    else
      false -> invalid(:target, :unknown_field)
      error -> error
    end
  end

  defp target(_other), do: invalid(:target, :expected_target_struct)

  defp wire(value, field) do
    case Map.fetch(Map.fetch!(@wire, field), Map.get(value, field)) do
      {:ok, wire} -> {:ok, wire}
      :error -> {:error, Error.new(:unknown_target, %{field: field, reason: :unknown_value})}
    end
  end

  defp nif(nil), do: {:ok, nil}

  defp nif({major, minor}) do
    if integer?(major, 1) and integer?(minor, 0),
      do: {:ok, {trunc(major), trunc(minor)}},
      else: invalid(:nif, :invalid_nif_version)
  end

  defp nif(_other), do: invalid(:nif, :invalid_nif_version)

  defp integer?(number, minimum) when is_number(number),
    do: number >= minimum and (is_integer(number) or trunc(number) == number)

  defp integer?(_other, _minimum), do: false

  defp version(nil, _field), do: :ok

  defp version(value, field) do
    if string?(value, 128) and Regex.match?(@version, value),
      do: :ok,
      else: invalid(field, :invalid_version)
  end

  defp optional_string(nil, _field, _maximum), do: :ok

  defp optional_string(value, field, maximum) do
    if string?(value, maximum), do: :ok, else: invalid(field, :invalid_string)
  end

  defp binding_evidence(nil), do: :ok

  defp binding_evidence(value) when is_map(value) do
    if Enum.sort(Map.keys(value)) == ~w(fingerprint interface_version module) and
         string?(value["module"], 1024) and Regex.match?(@module, value["module"]) and
         string?(value["interface_version"], 1024) and
         string?(value["fingerprint"], 64) and
         Regex.match?(~r/\A[0-9a-f]{64}\z/, value["fingerprint"]),
       do: :ok,
       else: invalid(:binding, :invalid_binding)
  end

  defp binding_evidence(_other), do: invalid(:binding, :invalid_binding)

  defp libraries(nil), do: :ok

  defp libraries(value) when is_map(value) and map_size(value) <= 256 do
    value
    |> Map.to_list()
    |> Enum.reduce_while(:ok, fn {name, evidence}, :ok ->
      result =
        if string?(name, 1024),
          do: library(evidence),
          else: invalid(:system_libraries, :invalid_name)

      continue(result)
    end)
  end

  defp libraries(_other), do: invalid(:system_libraries, :invalid_inventory)

  defp normalize_libraries(nil), do: nil

  defp normalize_libraries(value) do
    Map.new(value, fn {name, library} ->
      {name,
       Map.new([:symbols, :symbol_versions], fn field ->
         values = Map.get(library, field)
         {field, if(is_nil(values), do: nil, else: Enum.sort(values))}
       end)}
    end)
  end

  defp library(value) when is_map(value) do
    if Map.keys(value) -- [:symbols, :symbol_versions] == [] do
      with :ok <- symbols(Map.get(value, :symbols)),
           do: symbols(Map.get(value, :symbol_versions))
    else
      invalid(:system_libraries, :unknown_field)
    end
  end

  defp library(_other), do: invalid(:system_libraries, :invalid_library_evidence)

  defp symbols(nil), do: :ok

  defp symbols(values) do
    with {:ok, count, unique} <- symbol_list(values, 0, MapSet.new()) do
      if count == MapSet.size(unique),
        do: :ok,
        else: invalid(:system_libraries, :duplicate_symbol)
    end
  end

  defp symbol_list([], count, unique), do: {:ok, count, unique}

  defp symbol_list([value | rest], count, unique) when count < 4096 do
    if string?(value, 1024),
      do: symbol_list(rest, count + 1, MapSet.put(unique, value)),
      else: invalid(:system_libraries, :invalid_symbol)
  end

  defp symbol_list(_other, _count, _unique), do: invalid(:system_libraries, :invalid_symbols)

  def string?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  def required_binding(%{binding: nil}), do: missing(:binding)
  def required_binding(_evidence), do: :ok

  def find_artifact(manifest, id) do
    case Enum.find(manifest.data["artifacts"], &(&1["id"] == id)) do
      nil ->
        {:error,
         Error.new(:artifact_not_found, %{field: :artifact_id, reason: :selector_not_found})}

      artifact ->
        {:ok, artifact}
    end
  end

  def invalid(field, reason),
    do: {:error, Error.new(:invalid_configuration, %{field: field, reason: reason})}

  def missing(field),
    do: {:error, Error.new(:unknown_target, %{field: field, reason: :missing_evidence})}

  defp continue(:ok), do: {:cont, :ok}
  defp continue(error), do: {:halt, error}
end
