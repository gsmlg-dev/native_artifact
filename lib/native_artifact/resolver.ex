defmodule NativeArtifact.Resolver do
  @moduledoc """
  Pure, deterministic resolution from pinned metadata and explicit evidence.

  `resolve/3` accepts a Manifest, decoded data, or JSON binary and an atom-keyed
  evidence map. No path is read and no host information is inferred. Evidence
  fields are `:target` (`Target`), `:nif` (`{major, minor}`), `:erts`,
  `:os_version`, `:libc_version`, `:vm_variant`, `:system_libraries`, and
  `:binding`. Missing values mean unknown evidence, never a compatible default.

  All compatible baseline artifacts have equal priority. IDs sort diagnostics,
  not preference; ties return `ambiguous_artifact`. The optional `:artifact_id`
  selector narrows the candidates. `:manifest_limits` forwards Manifest limits.
  """

  alias NativeArtifact.{Error, Target}
  alias NativeArtifact.Resolver.Input

  @platform_fields ~w(os arch libc object_format pointer_width endianness cpu_baseline)

  @spec resolve(term(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def resolve(manifest, evidence, opts \\ []) do
    with {:ok, opts} <- Input.options(opts, [:artifact_id, :manifest_limits]),
         limits = Map.get(opts, :manifest_limits, []),
         {:ok, manifest} <- Input.manifest(manifest, limits),
         {:ok, selector} <- Input.selector(Map.get(opts, :artifact_id)),
         {:ok, evidence} <- Input.evidence(evidence),
         {:ok, candidates} <- candidates(manifest, selector) do
      choose(manifest, candidates, evidence, limits)
    end
  end

  defp candidates(manifest, nil), do: {:ok, manifest.data["artifacts"]}

  defp candidates(manifest, selector) do
    with {:ok, artifact} <- Input.find_artifact(manifest, selector), do: {:ok, [artifact]}
  end

  defp choose(manifest, candidates, evidence, limits) do
    target = target_data(evidence.target)

    inspected =
      candidates
      |> Enum.sort_by(& &1["id"])
      |> Enum.map(fn artifact ->
        platform = platform_reasons(artifact["target"], target)
        reasons = if platform == [], do: compatibility_reasons(artifact, evidence), else: platform
        %{artifact: artifact, platform?: platform == [], reasons: reasons}
      end)

    compatible = for %{artifact: artifact, reasons: []} <- inspected, do: artifact

    rejections =
      for %{artifact: artifact, reasons: [_ | _] = reasons} <- inspected,
          do: %{artifact_id: artifact["id"], reasons: reasons}

    case compatible do
      [artifact] ->
        {:ok,
         %{
           manifest: manifest,
           artifact: artifact,
           evidence: evidence,
           target: evidence.target,
           rejections: rejections,
           manifest_limits: limits
         }}

      [] ->
        code =
          cond do
            not Enum.any?(inspected, & &1.platform?) ->
              :unsupported_target

            Enum.any?(rejections, fn rejection ->
              Enum.any?(rejection.reasons, &(&1.reason == :missing_evidence))
            end) ->
              :unknown_target

            true ->
              :incompatible_artifact
          end

        {:error, Error.new(code, %{rejections: rejections})}

      many ->
        {:error,
         Error.new(:ambiguous_artifact, %{
           candidates: Enum.map(many, & &1["id"]),
           rejections: rejections
         })}
    end
  end

  defp target_data(%Target{} = target) do
    %{
      "os" => if(target.os == :linux, do: "linux", else: "macos"),
      "arch" => if(target.arch == :x86_64, do: "x86_64", else: "aarch64"),
      "libc" => %{glibc: "glibc", musl: "musl", none: "none"}[target.libc],
      "object_format" => if(target.object_format == :elf, do: "elf", else: "mach-o"),
      "pointer_width" => target.pointer_width,
      "endianness" => "little",
      "cpu_baseline" => if(target.cpu_baseline == :x86_64, do: "x86-64", else: "armv8-a")
    }
  end

  defp platform_reasons(required, actual) do
    for field <- @platform_fields,
        required[field] != actual[field],
        do: %{field: field, reason: :platform_mismatch}
  end

  defp compatibility_reasons(artifact, evidence) do
    required = artifact["compatibility"]

    nif_reasons(required["nif"], evidence.nif) ++
      minimum(required["min_erts"], evidence.erts, :erts) ++
      minimum(required["min_os_version"], evidence.os_version, :os_version) ++
      minimum(required["min_libc_version"], evidence.libc_version, :libc_version) ++
      equality(required["vm_variant"], evidence.vm_variant, :vm_variant) ++
      equality(artifact["binding"], evidence.binding, :binding) ++
      library_reasons(required["system_libraries"], evidence.system_libraries)
  end

  defp nif_reasons(_required, nil), do: [%{field: :nif, reason: :missing_evidence}]

  defp nif_reasons(required, actual) do
    expected = {trunc(required["major"]), trunc(required["minor"])}

    if Target.nif_compatible?(expected, actual),
      do: [],
      else: [%{field: :nif, reason: :incompatible_nif_api}]
  end

  defp minimum(nil, _actual, _field), do: []
  defp minimum(_required, nil, field), do: [%{field: field, reason: :missing_evidence}]

  defp minimum(required, actual, field) do
    if compare_versions(actual, required) in [:eq, :gt],
      do: [],
      else: [%{field: field, reason: :version_too_old}]
  end

  defp equality(_required, nil, field), do: [%{field: field, reason: :missing_evidence}]
  defp equality(value, value, _field), do: []
  defp equality(_required, _actual, field), do: [%{field: field, reason: :mismatch}]

  defp library_reasons([], _evidence), do: []

  defp library_reasons(_required, nil),
    do: [%{field: :system_libraries, reason: :missing_evidence}]

  defp library_reasons(required, evidence) do
    required
    |> Enum.with_index()
    |> Enum.flat_map(fn {library, index} ->
      reasons =
        case Map.fetch(evidence, library["name"]) do
          :error ->
            [%{field: :system_libraries, reason: :missing_library}]

          {:ok, found} ->
            symbols(library["required_symbols"], Map.get(found, :symbols), :symbols) ++
              symbols(
                library["symbol_versions"],
                Map.get(found, :symbol_versions),
                :symbol_versions
              )
        end

      Enum.map(reasons, &Map.put(&1, :library_index, index))
    end)
  end

  defp symbols([], _evidence, _field), do: []
  defp symbols(_required, nil, field), do: [%{field: field, reason: :missing_evidence}]

  defp symbols(required, evidence, field) do
    if MapSet.subset?(MapSet.new(required), MapSet.new(evidence)),
      do: [],
      else: [%{field: field, reason: :missing_symbols}]
  end

  defp compare_versions(left, right) do
    left = String.split(left, ".")
    right = String.split(right, ".")
    compare_parts(left, right)
  end

  defp compare_parts([], []), do: :eq
  defp compare_parts([], right), do: compare_parts(["0"], right)
  defp compare_parts(left, []), do: compare_parts(left, ["0"])

  defp compare_parts([left | left_rest], [right | right_rest]) do
    left = normalize_part(left)
    right = normalize_part(right)

    cond do
      byte_size(left) > byte_size(right) -> :gt
      byte_size(left) < byte_size(right) -> :lt
      left > right -> :gt
      left < right -> :lt
      true -> compare_parts(left_rest, right_rest)
    end
  end

  defp normalize_part(part) do
    case String.trim_leading(part, "0") do
      "" -> "0"
      normalized -> normalized
    end
  end
end
