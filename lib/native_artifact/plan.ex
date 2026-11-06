defmodule NativeArtifact.Plan do
  @moduledoc """
  Inspectable future actions for explicit precompiled or source consumption.

  Planning is pure: it does not obtain files, invoke recipes or install anything.
  `new/2` accepts `:evidence`, optional `:artifact_id` and `:manifest_limits`.
  `:mode` defaults to `:precompiled`; `:source` additionally requires an artifact
  ID and declarative `:build` recipe. There is no automatic source fallback.
  """

  alias NativeArtifact.{Error, Resolver}
  alias NativeArtifact.Resolver.Input

  @enforce_keys [:mode, :manifest, :evidence, :target, :binding, :actions]
  defstruct [
    :mode,
    :manifest,
    :evidence,
    :selector,
    :target,
    :binding,
    :artifact_id,
    :artifact,
    :archive,
    :build,
    :source_identity,
    sources: [],
    rejections: [],
    manifest_limits: [],
    actions: [],
    execution: :pending
  ]

  @adapters [NativeArtifact.Build.Make, NativeArtifact.Build.Cargo, NativeArtifact.Build.Zig]

  @spec new(term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  @type t :: %__MODULE__{}
  def new(manifest, opts \\ []) do
    with {:ok, opts} <-
           Input.options(opts, [:mode, :evidence, :artifact_id, :build, :manifest_limits]) do
      case Map.get(opts, :mode, :precompiled) do
        :precompiled -> precompiled(manifest, opts)
        :source -> source(manifest, opts)
        _other -> Input.invalid(:mode, :unsupported_mode)
      end
    end
  end

  @doc false
  @spec revalidate(term()) :: {:ok, t()} | {:error, Error.t()}
  def revalidate(%__MODULE__{} = supplied) do
    if MapSet.new(Map.keys(supplied)) == MapSet.new(Map.keys(__struct__())) do
      opts = [
        mode: supplied.mode,
        evidence: supplied.evidence,
        artifact_id: supplied.selector,
        manifest_limits: supplied.manifest_limits
      ]

      opts = if supplied.mode == :source, do: opts ++ [build: supplied.build], else: opts

      with {:ok, fresh} <- new(supplied.manifest, opts) do
        if fresh === supplied,
          do: {:ok, fresh},
          else: Input.invalid(:plan, :inconsistent_plan)
      end
    else
      Input.invalid(:plan, :invalid_plan_shape)
    end
  end

  def revalidate(_other), do: Input.invalid(:plan, :expected_plan)

  defp precompiled(manifest, opts) do
    if Map.has_key?(opts, :build) do
      Input.invalid(:build, :source_mode_required)
    else
      resolver_opts = Map.take(opts, [:artifact_id, :manifest_limits]) |> Map.to_list()

      with {:ok, resolution} <-
             Resolver.resolve(manifest, Map.get(opts, :evidence), resolver_opts) do
        artifact = resolution.artifact

        {:ok,
         %__MODULE__{
           mode: :precompiled,
           manifest: resolution.manifest,
           evidence: resolution.evidence,
           selector: Map.get(opts, :artifact_id),
           manifest_limits: resolution.manifest_limits,
           target: resolution.target,
           binding: artifact["binding"],
           artifact_id: artifact["id"],
           artifact: artifact,
           archive: artifact["archive"],
           sources: artifact["sources"],
           rejections: resolution.rejections,
           actions: [
             :obtain_archive,
             :verify_archive,
             :inspect_archive,
             :install_transactionally,
             :write_receipt
           ]
         }}
      end
    end
  end

  defp source(manifest, opts) do
    limits = Map.get(opts, :manifest_limits, [])

    with {:ok, manifest} <- Input.manifest(manifest, limits),
         {:ok, evidence} <- Input.evidence(Map.get(opts, :evidence)),
         :ok <- Input.required_binding(evidence),
         {:ok, id} <- source_selector(Map.get(opts, :artifact_id)),
         {:ok, artifact} <- Input.find_artifact(manifest, id),
         :ok <- binding_match(artifact, evidence),
         {:ok, build} <- recipe(Map.get(opts, :build)) do
      identity = %{
        origin: :local_build,
        artifact_id: id,
        native_version: artifact["native_version"],
        build_revision: artifact["build_revision"],
        provenance: artifact["provenance"],
        output_sha256: nil,
        receipt: :pending
      }

      {:ok,
       %__MODULE__{
         mode: :source,
         manifest: manifest,
         evidence: evidence,
         selector: id,
         manifest_limits: limits,
         target: evidence.target,
         binding: evidence.binding,
         artifact_id: id,
         build: build,
         source_identity: identity,
         actions: [
           :build_source,
           :verify_local_output,
           :install_transactionally,
           :write_source_receipt
         ]
       }}
    end
  end

  defp source_selector(nil), do: Input.invalid(:artifact_id, :required_for_source)
  defp source_selector(id), do: Input.selector(id)

  defp binding_match(artifact, evidence) do
    if artifact["binding"] == evidence.binding,
      do: :ok,
      else: {:error, Error.new(:incompatible_artifact, %{field: :binding, reason: :mismatch})}
  end

  defp recipe({adapter, opts}) when adapter in @adapters do
    allowed = if adapter == NativeArtifact.Build.Cargo, do: [:path, :locked], else: [:path]

    with {:ok, values} <- Input.options(opts, allowed),
         :ok <- recipe_path(Map.get(values, :path)),
         :ok <- locked(values) do
      {:ok, {adapter, opts}}
    end
  end

  defp recipe(_other), do: Input.invalid(:build, :unsupported_recipe)

  defp locked(values) do
    case Map.fetch(values, :locked) do
      :error -> :ok
      {:ok, true} -> :ok
      _other -> Input.invalid(:build, :locked_build_required)
    end
  end

  defp recipe_path(path) do
    valid =
      Input.string?(path, 16_384) and
        length(String.to_charlist(path)) <= 4096 and
        not Regex.match?(~r/\A[A-Za-z]:/, path) and
        not String.contains?(path, "\\") and
        not Regex.match?(~r/[\x00-\x1f\x7f]/, path) and
        Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))

    if valid, do: :ok, else: Input.invalid(:build, :unsafe_recipe_path)
  end
end
